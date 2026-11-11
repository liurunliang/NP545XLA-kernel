// SPDX-License-Identifier: GPL-2.0-only
/* Transitional status bridge. It owns no I2C client and cannot control power. */
#include <linux/capability.h>
#include <linux/device.h>
#include <linux/fs.h>
#include <linux/ktime.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/power_supply.h>
#include <linux/uaccess.h>
#include <linux/workqueue.h>
#include "np545_power_supply.h"

static bool test_mode;
module_param(test_mode, bool, 0400);
MODULE_PARM_DESC(test_mode, "Allow a synthetic QEMU reporting test; never enables hardware access");

static DEFINE_MUTEX(report_lock);
static struct np545_report report;
static bool writer_open;
static bool report_changed;
static u64 last_stamp;
static struct device *root;
/* Only the worker and module exit access supply. */
static struct power_supply *supply;
static void update_supply(struct work_struct *work);
static DECLARE_DELAYED_WORK(update_work, update_supply);

static bool fresh_locked(u64 now)
{
	u64 stamp = le64_to_cpu(report.boottime_ns);

	return writer_open && (le32_to_cpu(report.valid) & NP545_REPORT_ONLINE) &&
		now - stamp < NP545_REPORT_TTL_NS;
}

static enum power_supply_property properties[] = {
	POWER_SUPPLY_PROP_ONLINE,
	POWER_SUPPLY_PROP_USB_TYPE,
	POWER_SUPPLY_PROP_VOLTAGE_MAX,
	POWER_SUPPLY_PROP_CURRENT_MAX,
	POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT,
	POWER_SUPPLY_PROP_CONSTANT_CHARGE_CURRENT,
	POWER_SUPPLY_PROP_CONSTANT_CHARGE_VOLTAGE,
};

static int get_property(struct power_supply *psy,
			enum power_supply_property prop, union power_supply_propval *val)
{
	u32 valid;
	int ret = 0;

	mutex_lock(&report_lock);
	valid = le32_to_cpu(report.valid);
	if (!fresh_locked(ktime_get_boottime_ns())) {
		ret = -ENODATA;
		goto out;
	}
	if ((prop == POWER_SUPPLY_PROP_VOLTAGE_MAX || prop == POWER_SUPPLY_PROP_CURRENT_MAX) &&
	    !(valid & NP545_REPORT_CONTRACT)) {
		ret = -ENODATA;
		goto out;
	}
	if ((prop == POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT ||
	     prop == POWER_SUPPLY_PROP_CONSTANT_CHARGE_CURRENT ||
	     prop == POWER_SUPPLY_PROP_CONSTANT_CHARGE_VOLTAGE) &&
	    !(valid & NP545_REPORT_SETTINGS)) {
		ret = -ENODATA;
		goto out;
	}
	switch (prop) {
	case POWER_SUPPLY_PROP_ONLINE:
		val->intval = le32_to_cpu(report.online);
		break;
	case POWER_SUPPLY_PROP_USB_TYPE:
		val->intval = valid & NP545_REPORT_CONTRACT ?
			POWER_SUPPLY_USB_TYPE_PD : POWER_SUPPLY_USB_TYPE_UNKNOWN;
		break;
	case POWER_SUPPLY_PROP_VOLTAGE_MAX:
		val->intval = le32_to_cpu(report.voltage_max_uv);
		break;
	case POWER_SUPPLY_PROP_CURRENT_MAX:
		val->intval = le32_to_cpu(report.current_max_ua);
		break;
	case POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT:
		val->intval = le32_to_cpu(report.input_limit_ua);
		break;
	case POWER_SUPPLY_PROP_CONSTANT_CHARGE_CURRENT:
		val->intval = le32_to_cpu(report.charge_current_ua);
		break;
	case POWER_SUPPLY_PROP_CONSTANT_CHARGE_VOLTAGE:
		val->intval = le32_to_cpu(report.charge_voltage_uv);
		break;
	default:
		ret = -EINVAL;
	}
out:
	mutex_unlock(&report_lock);
	return ret;
}

static const struct power_supply_desc description = {
	.name = "np545-usb-c",
	.type = POWER_SUPPLY_TYPE_USB,
	.usb_types = BIT(POWER_SUPPLY_USB_TYPE_UNKNOWN) | BIT(POWER_SUPPLY_USB_TYPE_PD),
	.properties = properties,
	.num_properties = ARRAY_SIZE(properties),
	.get_property = get_property,
};

static char *consumers[] = { "np545-battery" };

static void update_supply(struct work_struct *work)
{
	struct power_supply_config config = {
		.supplied_to = consumers,
		.num_supplicants = ARRAY_SIZE(consumers),
		.no_wakeup_source = true,
	};
	bool fresh, changed;
	unsigned long delay = 0;
	u64 now;

	mutex_lock(&report_lock);
	now = ktime_get_boottime_ns();
	fresh = fresh_locked(now);
	changed = report_changed;
	report_changed = false;
	if (fresh)
		delay = max_t(unsigned long, 1, nsecs_to_jiffies(
			le64_to_cpu(report.boottime_ns) + NP545_REPORT_TTL_NS -
			now));
	mutex_unlock(&report_lock);
	/* Registration invokes get_property; never hold report_lock here. */
	if (fresh && !supply) {
		supply = power_supply_register(root, &description, &config);
		if (IS_ERR(supply)) {
			pr_warn_ratelimited("np545 power supply registration: %ld\n", PTR_ERR(supply));
			supply = NULL;
		}
	} else if (!fresh && supply) {
		power_supply_unregister(supply);
		supply = NULL;
	} else if (fresh && changed) {
		power_supply_changed(supply);
	}
	/* A dead or frozen reporter must not leave a permanently online supply. */
	if (fresh)
		schedule_delayed_work(&update_work, delay);
}

static int report_open(struct inode *inode, struct file *file)
{
	int ret = 0;

	if (!(file->f_mode & FMODE_WRITE) || !capable(CAP_SYS_ADMIN))
		return -EPERM;
	mutex_lock(&report_lock);
	if (writer_open)
		ret = -EBUSY;
	else {
		writer_open = true;
		last_stamp = 0;
		memset(&report, 0, sizeof(report));
	}
	mutex_unlock(&report_lock);
	return ret;
}

static int report_release(struct inode *inode, struct file *file)
{
	mutex_lock(&report_lock);
	writer_open = false;
	memset(&report, 0, sizeof(report));
	mutex_unlock(&report_lock);
	mod_delayed_work(system_wq, &update_work, 0);
	return 0;
}

static ssize_t report_write(struct file *file, const char __user *buffer,
			    size_t count, loff_t *offset)
{
	struct np545_report next;
	u64 stamp, now;
	u32 valid, online;
	int ret = -EINVAL;

	if (count != sizeof(next))
		return -EMSGSIZE;
	if (copy_from_user(&next, buffer, sizeof(next)))
		return -EFAULT;
	stamp = le64_to_cpu(next.boottime_ns);
	now = ktime_get_boottime_ns();
	valid = le32_to_cpu(next.valid);
	online = le32_to_cpu(next.online);
	if (le32_to_cpu(next.version) != NP545_REPORT_VERSION || valid & ~7U || online > 1 ||
	    (valid && !(valid & NP545_REPORT_ONLINE)) || (!valid && online) ||
	    ((valid & NP545_REPORT_CONTRACT) && !online) ||
	    ((valid & NP545_REPORT_SETTINGS) && !online))
		return -EINVAL;
	if (valid & NP545_REPORT_CONTRACT) {
		u32 uv = le32_to_cpu(next.voltage_max_uv);
		u32 ua = le32_to_cpu(next.current_max_ua);

		if (uv < 5000000 || uv > 20000000 || !ua || ua > 5000000)
			return -ERANGE;
	} else if (next.voltage_max_uv || next.current_max_ua) {
		return -EINVAL;
	}
	if (valid & NP545_REPORT_SETTINGS) {
		u32 uv = le32_to_cpu(next.charge_voltage_uv);

		if (le32_to_cpu(next.input_limit_ua) > 6350000 ||
		    le32_to_cpu(next.charge_current_ua) > 8128000 || uv < 6000000 || uv > 9000000)
			return -ERANGE;
	} else if (next.input_limit_ua || next.charge_current_ua || next.charge_voltage_uv) {
		return -EINVAL;
	}
	if (!stamp || stamp > now || now - stamp >= NP545_REPORT_TTL_NS)
		return -ESTALE;
	mutex_lock(&report_lock);
	if (stamp > last_stamp) {
		report_changed |= report.valid != next.valid ||
			memcmp(&report.online, &next.online,
			       sizeof(next) - offsetof(struct np545_report, online));
		report = next;
		last_stamp = stamp;
		ret = count;
	}
	mutex_unlock(&report_lock);
	if (ret > 0)
		mod_delayed_work(system_wq, &update_work, 0);
	return ret;
}

static const struct file_operations report_ops = {
	.owner = THIS_MODULE,
	.open = report_open,
	.release = report_release,
	.write = report_write,
};

static struct miscdevice report_device = {
	.minor = MISC_DYNAMIC_MINOR,
	.name = "np545-power-supply",
	.fops = &report_ops,
	.mode = 0600,
};

static int __init bridge_init(void)
{
	int ret;

	BUILD_BUG_ON(sizeof(struct np545_report) != 40);
	if (!test_mode && !of_machine_is_compatible("samsung,np545xla"))
		return -ENODEV;
	root = root_device_register("np545-power-supply");
	if (IS_ERR(root))
		return PTR_ERR(root);
	ret = misc_register(&report_device);
	if (ret) {
		root_device_unregister(root);
		return ret;
	}
	schedule_delayed_work(&update_work, HZ);
	return 0;
}

static void __exit bridge_exit(void)
{
	misc_deregister(&report_device);
	cancel_delayed_work_sync(&update_work);
	if (supply)
		power_supply_unregister(supply);
	root_device_unregister(root);
}
module_init(bridge_init);
module_exit(bridge_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Read-only NP545XLA power_supply status bridge; no charging control");
