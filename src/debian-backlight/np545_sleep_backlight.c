// SPDX-License-Identifier: GPL-2.0-only
/* Lid and sleep backlight quirk for the NP545XLA USB lid-edge trial. */
#include <linux/delay.h>
#include <linux/input.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/pm_runtime.h>
#include <linux/regmap.h>
#include <linux/spmi.h>
#include <linux/string_helpers.h>
#include <linux/suspend.h>
#include <linux/workqueue.h>

#define PWM_BASE 0xbc00
#define VALUE_LO (PWM_BASE + 0x44)
#define SYNC     (PWM_BASE + 0x47)
#define DUTY_MASK 0x01ff

enum light_state { IDLE, BLANKED, NEEDS_RESTORE };

struct np545_backlight {
	struct device *dev;
	struct regmap *map;
	struct mutex lock;
	struct device_node *keys_node;
	struct input_handler handler;
	struct input_handle handle;
	struct delayed_work lid_work;
	spinlock_t schedule_lock;
	unsigned int retries;
	bool lid_closed;	/* Published by the input callback under event_lock. */
	bool pm_suspended;
	bool disarmed;
	u16 original;
	enum light_state state;
};

static int verify_channel(struct regmap *map)
{
	/* Identify the peripheral before reading any configuration. */
	static const u8 registers[][2] = {
		{ 0x04, 0x13 }, { 0x05, 0x0b }, /* LPG, dedicated PWM */
		{ 0x41, 0x07 }, { 0x42, 0x06 }, /* 9 bits, 585.9375 Hz */
		{ 0x46, 0x80 },                  /* output enabled */
	};
	unsigned int i, value;
	int ret;

	for (i = 0; i < ARRAY_SIZE(registers); i++) {
		ret = regmap_read(map, PWM_BASE + registers[i][0], &value);
		if (ret)
			return ret;
		if (value != registers[i][1])
			return -ESTALE;
	}
	return 0;
}

static int read_duty(struct regmap *map, u16 *raw)
{
	__le16 bytes;
	int ret = regmap_bulk_read(map, VALUE_LO, &bytes, sizeof(bytes));

	if (!ret)
		*raw = le16_to_cpu(bytes);
	return ret;
}

static int set_duty(struct regmap *map, u16 raw)
{
	__le16 bytes = cpu_to_le16(raw);
	u16 previous, actual;
	int ret;

	ret = read_duty(map, &previous);
	if (ret)
		return ret;
	/* The upper seven bits are reserved. Refuse to overwrite an unexpected
	 * change while this channel was owned by firmware over suspend.
	 */
	if ((previous ^ raw) & ~DUTY_MASK)
		return -ESTALE;
	ret = regmap_bulk_write(map, VALUE_LO, &bytes, sizeof(bytes));
	if (!ret)
		ret = regmap_write(map, SYNC, BIT(0));
	if (!ret)
		ret = read_duty(map, &actual);
	if (ret)
		return ret;
	return actual == raw ? 0 : -EIO;
}

/* All PWM/state operations hold light->lock. A saved word pins the module
 * until verified restoration. A service stop uses disarm before unloading.
 */
static int restore(struct np545_backlight *light, const char *reason)
{
	struct device *dev = light->dev;
	int i, ret;

	if (light->state == IDLE)
		return 0;
	light->state = NEEDS_RESTORE;
	for (i = 0; i < 3; i++) {
		ret = verify_channel(light->map);
		if (!ret)
			ret = set_duty(light->map, light->original);
		if (!ret) {
			light->state = IDLE;
			dev_info(dev, "%s: restored PWM duty %u\n", reason, light->original & DUTY_MASK);
			module_put(THIS_MODULE);
			return 0;
		}
		if (ret == -ESTALE)
			break;
		if (i < 2)
			usleep_range(1000, 2000);
	}
	dev_err(dev, "PWM restore failed (%d); original word 0x%04x retained\n", ret, light->original);
	return ret;
}

static int blank(struct np545_backlight *light, const char *reason)
{
	u16 raw;
	int ret;

	if (light->state == BLANKED)
		return 0;
	ret = verify_channel(light->map);
	if (ret)
		return ret;
	if (light->state == IDLE) {
		ret = read_duty(light->map, &raw);
		if (ret)
			return ret;
		if (!try_module_get(THIS_MODULE))
			return -EBUSY;
		light->original = raw;
	}
	/* A failed restore can leave zero in the peripheral. Keep the original
	 * word across a retry or a second blank reason, even for duty zero.
	 */
	light->state = NEEDS_RESTORE;
	ret = set_duty(light->map, light->original & ~DUTY_MASK);
	if (ret) {
		dev_err(light->dev, "%s: cannot blank PWM (%d); rolling back\n", reason, ret);
		restore(light, "blank rollback");
		return ret;
	}
	light->state = BLANKED;
	dev_info(light->dev, "%s: verified PWM duty 0 (saved %u)\n",
		 reason, light->original & DUTY_MASK);
	return 0;
}

/* Never wake an idle parent to probe, retry, or handle forced detachment. */
static int while_bus_active(struct np545_backlight *light,
			    int (*action)(struct np545_backlight *, const char *), const char *reason)
{
	struct device *dev = light->dev;
	struct device *pmic = dev->parent, *held[3], *chain[3];
	unsigned int i, nr = 0;
	int ret;

	if (!pmic || !pmic->parent || !pmic->parent->parent ||
	    !pmic->driver || !dev_get_drvdata(pmic))
		return -ENODEV;
	chain[0] = pmic->parent->parent;
	chain[1] = pmic->parent;
	chain[2] = pmic;
	for (i = 0; i < ARRAY_SIZE(chain); i++) {
		if (!pm_runtime_enabled(chain[i]))
			continue;
		ret = pm_runtime_get_if_active(chain[i]);
		if (ret <= 0) {
			ret = ret < 0 ? ret : -EHOSTDOWN;
			goto out;
		}
		held[nr++] = chain[i];
	}
	ret = action(light, reason);
out:
	while (nr)
		pm_runtime_put_noidle(held[--nr]);
	return ret;
}

static int check_target(struct np545_backlight *light, const char *reason)
{
	return verify_channel(light->map);
}

static int reconcile(struct np545_backlight *light, const char *reason)
{
	bool closed = READ_ONCE(light->lid_closed);
	bool dark = !light->disarmed && (light->pm_suspended || closed);

	if (!reason)
		reason = closed ? "lid close" : "lid open";

	if ((dark && light->state == BLANKED) || (!dark && light->state == IDLE))
		return 0;
	return while_bus_active(light, dark ? blank : restore, reason);
}

static void retry_lid_work(struct np545_backlight *light, int error)
{
	static const unsigned int delays_ms[] = { 50, 200, 600 };
	unsigned long flags;

	switch (error) {
	case -EAGAIN:
	case -EBUSY:
	case -EIO:
	case -EREMOTEIO:
	case -ETIMEDOUT:
	case -EHOSTDOWN:
		break;
	default:
		return;
	}
	spin_lock_irqsave(&light->schedule_lock, flags);
	/* queue_delayed_work leaves an already queued fresh edge at zero delay. */
	if (!light->disarmed && !light->pm_suspended && light->retries < ARRAY_SIZE(delays_ms) &&
	    queue_delayed_work(system_freezable_wq, &light->lid_work,
			       msecs_to_jiffies(delays_ms[light->retries])))
		light->retries++;
	spin_unlock_irqrestore(&light->schedule_lock, flags);
}

static void stop_lid_work(struct np545_backlight *light)
{
	unsigned long flags;

	spin_lock_irqsave(&light->schedule_lock, flags);
	light->disarmed = true;
	spin_unlock_irqrestore(&light->schedule_lock, flags);
}

static void reset_retries(struct np545_backlight *light)
{
	unsigned long flags;

	spin_lock_irqsave(&light->schedule_lock, flags);
	light->retries = 0;
	spin_unlock_irqrestore(&light->schedule_lock, flags);
}

static int np545_suspend_active(struct device *dev)
{
	struct np545_backlight *light = dev_get_drvdata(dev);
	int ret;

	mutex_lock(&light->lock);
	light->pm_suspended = true;
	ret = reconcile(light, "PM suspend");
	if (ret) {
		/* This failed device will not get resume. Reconcile the independent
		 * lid request after thaw even if there is no new switch event.
		 */
		light->pm_suspended = false;
		reset_retries(light);
		retry_lid_work(light, ret);
	}
	mutex_unlock(&light->lock);
	return ret;
}

static int verify_closed_after_sleep(struct np545_backlight *light, const char *reason)
{
	u16 raw, dark = light->original & ~DUTY_MASK;
	int ret = verify_channel(light->map);

	if (!ret)
		ret = read_duty(light->map, &raw);
	if (!ret && raw != dark) {
		ret = set_duty(light->map, dark);
		if (!ret)
			dev_info(light->dev, "%s: reasserted PWM duty 0 for closed lid\n", reason);
	}
	if (!ret)
		light->state = BLANKED;
	return ret;
}

static int np545_resume(struct device *dev)
{
	struct np545_backlight *light = dev_get_drvdata(dev);
	int ret;

	mutex_lock(&light->lock);
	light->pm_suspended = false;
	reset_retries(light);
	if (!light->disarmed && READ_ONCE(light->lid_closed) && light->state == BLANKED) {
		/* Firmware may have changed duty while asleep. Keep the original
		 * and require a fresh hardware read before declaring it blanked.
		 */
		light->state = NEEDS_RESTORE;
		ret = while_bus_active(light, verify_closed_after_sleep, "PM resume");
	} else {
		ret = reconcile(light, "PM resume");
	}
	retry_lid_work(light, ret);
	mutex_unlock(&light->lock);
	return ret;
}

/* Complete follows every device's normal resume, including gpio_keys'
 * resampling of the physical switch. Never brighten based on an old open
 * value while the input device is still resuming.
 */
static void np545_complete(struct device *dev)
{
	struct np545_backlight *light = dev_get_drvdata(dev);
	int ret;

	if (!light->pm_suspended)
		return;
	ret = np545_resume(dev);
	if (ret)
		dev_err(dev, "PM resume: PWM update failed (%d)\n", ret);
}

static int manual_restore(struct device *dev, bool disarm)
{
	struct np545_backlight *light = dev_get_drvdata(dev);
	unsigned int flags = lock_system_sleep();
	bool stopped = false;
	int ret;

	mutex_lock(&light->lock);
	if (light->pm_suspended || (!disarm && !light->disarmed && READ_ONCE(light->lid_closed))) {
		ret = -EBUSY;
	} else {
		if (disarm) {
			stop_lid_work(light);
			stopped = true;
		}
		ret = reconcile(light, disarm ? "disarm" : "recovery");
	}
	mutex_unlock(&light->lock);
	if (stopped)
		cancel_delayed_work_sync(&light->lid_work);
	unlock_system_sleep(flags);
	return ret;
}

static ssize_t recover_store(struct device *dev, struct device_attribute *attr,
			     const char *buf, size_t count)
{
	int ret = sysfs_streq(buf, "1") ? manual_restore(dev, false) : -EINVAL;

	return ret ? ret : count;
}
static DEVICE_ATTR_WO(recover);

static ssize_t disarm_store(struct device *dev, struct device_attribute *attr,
			    const char *buf, size_t count)
{
	int ret = sysfs_streq(buf, "1") ? manual_restore(dev, true) : -EINVAL;

	return ret ? ret : count;
}
static DEVICE_ATTR_WO(disarm);

static struct attribute *np545_attrs[] = { &dev_attr_recover.attr, &dev_attr_disarm.attr, NULL };
ATTRIBUTE_GROUPS(np545);

static void lid_work(struct work_struct *work)
{
	struct np545_backlight *light = container_of(to_delayed_work(work), struct np545_backlight, lid_work);
	int ret;

	mutex_lock(&light->lock);
	/* The PM callbacks own the hardware throughout system suspend. The
	 * freezable worker will see the latest switch state once userspace thaws.
	 */
	if (!light->pm_suspended && !light->disarmed) {
		ret = reconcile(light, NULL);
		retry_lid_work(light, ret);
		if (ret)
			dev_err_ratelimited(light->dev, "lid event: PWM update failed (%d)\n", ret);
	}
	mutex_unlock(&light->lock);
}

static void set_lid_state(struct np545_backlight *light, bool closed)
{
	unsigned long flags;

	spin_lock_irqsave(&light->schedule_lock, flags);
	WRITE_ONCE(light->lid_closed, closed);
	if (!light->disarmed) {
		light->retries = 0;
		mod_delayed_work(system_freezable_wq, &light->lid_work, 0);
	}
	spin_unlock_irqrestore(&light->schedule_lock, flags);
}

static void lid_changed(struct input_handle *handle, unsigned int type, unsigned int code, int value)
{
	if (type == EV_SW && code == SW_LID)
		set_lid_state(handle->private, !!value);
}

static bool lid_match(struct input_handler *handler, struct input_dev *input)
{
	struct np545_backlight *light = handler->private;

	return input->dev.parent && input->dev.parent->of_node == light->keys_node;
}

static int lid_connect(struct input_handler *handler, struct input_dev *input,
		       const struct input_device_id *id)
{
	struct np545_backlight *light = handler->private;
	struct input_handle *handle = &light->handle;
	unsigned long flags;
	int ret;

	if (handle->dev)
		return -EBUSY;
	/* input_disconnect_device can reset the old open count before close.
	 * input_mutex and input_unregister_handle's RCU grace period make this
	 * a fresh handle for each new connection.
	 */
	*handle = (struct input_handle) {
		.dev = input, .handler = handler, .name = handler->name, .private = light,
	};
	ret = input_register_handle(handle);
	if (ret)
		goto clear;
	ret = input_open_device(handle);
	if (ret) {
		input_unregister_handle(handle);
		set_lid_state(light, false);
		goto clear;
	}
	/* Report the existing physical state too. Serialize this sample with
	 * input events so an open/close racing connect cannot be overwritten.
	 */
	spin_lock_irqsave(&input->event_lock, flags);
	set_lid_state(light, test_bit(SW_LID, input->sw));
	spin_unlock_irqrestore(&input->event_lock, flags);
	dev_info(light->dev, "board lid handler active on %s\n", dev_name(&input->dev));
	return 0;
clear:
	handle->dev = NULL;
	return ret;
}

static void lid_disconnect(struct input_handle *handle)
{
	struct np545_backlight *light = handle->private;

	input_close_device(handle);
	input_unregister_handle(handle);
	handle->dev = NULL;
	set_lid_state(light, false);
}

static const struct input_device_id lid_ids[] = {
	{
		.flags = INPUT_DEVICE_ID_MATCH_BUS | INPUT_DEVICE_ID_MATCH_EVBIT | INPUT_DEVICE_ID_MATCH_SWBIT,
		.bustype = BUS_HOST,
		.evbit = { BIT_MASK(EV_SW) },
		.swbit = { BIT_MASK(SW_LID) },
	}, { }
};

static int __init np545_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct device *pmic = dev->parent;
	struct np545_backlight *light;
	struct device_node *expected;
	int ret;

	expected = of_find_node_by_path("/soc@0/spmi@c440000/pmic@5/pwm");
	if (!expected)
		return -ENODEV;
	ret = dev->of_node == expected && of_device_is_available(expected);
	of_node_put(expected);
	if (!ret || !pmic || dev->of_node->parent != pmic->of_node ||
	    !of_device_is_compatible(pmic->of_node, "qcom,pmc8180c") ||
	    !of_device_is_compatible(pmic->of_node->parent, "qcom,spmi-pmic-arb") ||
	    !pmic->bus || strcmp(pmic->bus->name, "spmi") ||
	    !pmic->driver || strcmp(pmic->driver->name, "pmic-spmi") ||
	    to_spmi_device(pmic)->usid != 5)
		return -ENODEV;
	light = devm_kzalloc(dev, sizeof(*light), GFP_KERNEL);
	if (!light)
		return -ENOMEM;
	light->map = dev_get_regmap(pmic, NULL);
	if (!light->map)
		return -ENODEV;
	light->dev = dev;
	mutex_init(&light->lock);
	spin_lock_init(&light->schedule_lock);
	INIT_DELAYED_WORK(&light->lid_work, lid_work);
	platform_set_drvdata(pdev, light);
	ret = while_bus_active(light, check_target, "probe");
	if (ret)
		return dev_err_probe(dev, ret, "board PWM signature mismatch or unreadable\n");
	light->keys_node = of_find_node_by_path("/gpio-keys");
	if (!of_device_is_available(light->keys_node) ||
	    !of_device_is_compatible(light->keys_node, "gpio-keys")) {
		of_node_put(light->keys_node);
		return -ENODEV;
	}
	light->handler = (struct input_handler) {
		.private = light, .name = "np545-lid-backlight", .id_table = lid_ids,
		.match = lid_match, .event = lid_changed, .connect = lid_connect,
		.disconnect = lid_disconnect,
	};
	ret = input_register_handler(&light->handler);
	if (ret)
		of_node_put(light->keys_node);
	return ret;
}

static void np545_remove(struct platform_device *pdev)
{
	struct np545_backlight *light = platform_get_drvdata(pdev);

	mutex_lock(&light->lock);
	stop_lid_work(light);
	mutex_unlock(&light->lock);
	input_unregister_handler(&light->handler);
	cancel_delayed_work_sync(&light->lid_work);
	of_node_put(light->keys_node);

	mutex_lock(&light->lock);
	/* A forced parent removal may be the last chance to restore the saved
	 * word. Normal removal follows a successful disarm and does no PWM I/O.
	 */
	if (light->state != IDLE && while_bus_active(light, restore, "device removal")) {
		dev_err(&pdev->dev, "PMIC removed before recovery; original PWM word 0x%04x\n",
			light->original);
		light->state = IDLE;
		module_put(THIS_MODULE);
	}
	mutex_unlock(&light->lock);
}

static const struct dev_pm_ops np545_pm = {
	.suspend = np545_suspend_active,
	.complete = np545_complete,
};

static const struct of_device_id np545_of_match[] = {
	{ .compatible = "qcom,pmc8180c-lpg" }, { }
};
/* No generic OF module alias. Load only on explicit request. */
static struct platform_driver np545_driver = {
	.remove = np545_remove,
	.driver = {
		.name = "np545-sleep-backlight",
		.of_match_table = np545_of_match,
		.pm = &np545_pm,
		.dev_groups = np545_groups,
	},
};

static int __init np545_init(void)
{
	struct device_node *chosen;
	const char *args;
	char **argv;
	int argc, ret;

	if (!of_machine_is_compatible("samsung,np545xla") ||
	    !of_machine_is_compatible("qcom,sc8180x"))
		return -ENODEV;
	chosen = of_find_node_by_path("/chosen");
	ret = of_property_read_string(chosen, "bootargs", &args);
	argv = ret ? NULL : argv_split(GFP_KERNEL, args, &argc);
	of_node_put(chosen);
	if (ret)
		return -ENODEV;
	if (!argv)
		return -ENOMEM;
	ret = match_string((const char *const *)argv, argc, "np545.lid_edge=1");
	argv_free(argv);
	if (ret < 0)
		return -ENODEV;
	return platform_driver_probe(&np545_driver, np545_probe);
}
module_init(np545_init);

static void __exit np545_exit(void)
{
	platform_driver_unregister(&np545_driver);
}
module_exit(np545_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("NP545XLA lid-edge sleep backlight quirk");
