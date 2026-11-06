// SPDX-License-Identifier: GPL-2.0-only
/* Sleep-only backlight quirk for the NP545XLA USB lid-edge trial. */
#include <linux/delay.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/pm_runtime.h>
#include <linux/regmap.h>
#include <linux/spmi.h>
#include <linux/string_helpers.h>
#include <linux/suspend.h>

#define PWM_BASE 0xbc00
#define VALUE_LO (PWM_BASE + 0x44)
#define SYNC     (PWM_BASE + 0x47)
#define DUTY_MASK 0x01ff

enum light_state { IDLE, BLANKED, NEEDS_RESTORE };

struct np545_backlight {
	struct regmap *map;
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

/* The device PM core serializes its callbacks; explicit recovery also takes
 * the system sleep lock. Hold a module reference until verified
 * restoration, so stopping the service never strands a pending restore.
 */
static int restore(struct device *dev)
{
	struct np545_backlight *light = dev_get_drvdata(dev);
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
			dev_info(dev, "restored PWM duty %u\n", light->original & DUTY_MASK);
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

static int np545_suspend(struct device *dev)
{
	struct np545_backlight *light = dev_get_drvdata(dev);
	u16 raw;
	int ret;

	if (light->state == BLANKED)
		return 0;
	if (light->state == NEEDS_RESTORE) {
		ret = restore(dev);
		if (ret)
			return ret;
	}
	ret = verify_channel(light->map);
	if (!ret)
		ret = read_duty(light->map, &raw);
	if (ret)
		return ret;
	if (!try_module_get(THIS_MODULE))
		return -EBUSY;
	light->original = raw;
	light->state = NEEDS_RESTORE;
	ret = set_duty(light->map, raw & ~DUTY_MASK);
	if (ret) {
		dev_err(dev, "cannot blank PWM (%d); rolling back\n", ret);
		restore(dev);
		return ret;
	}
	light->state = BLANKED;
	dev_info(dev, "verified PWM duty 0 (saved %u)\n", light->original & DUTY_MASK);
	return 0;
}

/* Never wake an idle parent to probe, retry, or handle forced detachment. */
static int while_bus_active(struct device *dev, int (*action)(struct device *))
{
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
	ret = action(dev);
out:
	while (nr)
		pm_runtime_put_noidle(held[--nr]);
	return ret;
}

static int check_target(struct device *dev)
{
	struct np545_backlight *light = dev_get_drvdata(dev);

	return verify_channel(light->map);
}

static int np545_suspend_active(struct device *dev)
{
	return while_bus_active(dev, np545_suspend);
}

static int np545_resume(struct device *dev)
{
	struct np545_backlight *light = dev_get_drvdata(dev);

	if (light->state == IDLE)
		return 0;
	light->state = NEEDS_RESTORE;
	return while_bus_active(dev, restore);
}

static ssize_t recover_store(struct device *dev, struct device_attribute *attr,
			     const char *buf, size_t count)
{
	unsigned int flags;
	int ret;

	if (!sysfs_streq(buf, "1"))
		return -EINVAL;
	flags = lock_system_sleep();
	ret = np545_resume(dev);
	unlock_system_sleep(flags);
	return ret ? ret : count;
}
static DEVICE_ATTR_WO(recover);
static struct attribute *np545_attrs[] = { &dev_attr_recover.attr, NULL };
ATTRIBUTE_GROUPS(np545);

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
	platform_set_drvdata(pdev, light);
	ret = while_bus_active(dev, check_target);
	if (ret)
		return dev_err_probe(dev, ret, "board PWM signature mismatch or unreadable\n");
	dev_info(dev, "sleep backlight bound; PWM unchanged\n");
	return 0;
}

static void np545_remove(struct platform_device *pdev)
{
	struct np545_backlight *light = platform_get_drvdata(pdev);

	/* Only forced parent removal can reach this point with a pending word.
	 * Restore if the PMIC is still available; never leave a reference on a
	 * driver state that device removal is about to destroy.
	 */
	if (light->state != IDLE && np545_resume(&pdev->dev)) {
		dev_err(&pdev->dev, "PMIC removed before recovery; original PWM word 0x%04x\n",
			light->original);
		light->state = IDLE;
		module_put(THIS_MODULE);
	}
}

static const struct dev_pm_ops np545_pm = {
	.suspend = np545_suspend_active,
	.resume = np545_resume,
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
