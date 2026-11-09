// SPDX-License-Identifier: GPL-2.0
// One-shot inspection of the existing NP545XLA PMIC RTC device.
// Reads only registers used by rtc-pm8xxx.c; no RTC/IRQ registration or writes.
#include <linux/delay.h>
#include <linux/ktime.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_platform.h>
#include <linux/platform_device.h>
#include <linux/regmap.h>
#include <linux/unaligned.h>

static int read_counter(struct regmap *map, u32 *seconds)
{
	u8 value[4];
	unsigned int low;
	int ret;

	ret = regmap_bulk_read(map, 0x6048, value, sizeof(value));
	if (ret)
		return ret;
	/* Same rollover check as pm8xxx_rtc_read_raw(). */
	ret = regmap_read(map, 0x6048, &low);
	if (ret)
		return ret;
	if (low < value[0]) {
		ret = regmap_bulk_read(map, 0x6048, value, sizeof(value));
		if (ret)
			return ret;
	}
	*seconds = get_unaligned_le32(value);
	return 0;
}

static int __init np545_rtc_diag_init(void)
{
	struct device_node *node;
	struct platform_device *pdev;
	struct device *parent;
	struct regmap *map;
	u8 alarm[4];
	u32 sid, first, second;
	unsigned int control, alarm_control;
	s64 before_ms, after_ms;
	int ret = -ENODEV;

	if (!of_machine_is_compatible("samsung,np545xla"))
		return -ENODEV;
	node = of_find_node_by_path("/soc@0/spmi@c440000/pmic@0/rtc@6000");
	if (!node)
		return -ENODEV;
	if (!of_device_is_compatible(node, "qcom,pm8941-rtc")) {
		of_node_put(node);
		return -ENODEV;
	}
	pdev = of_find_device_by_node(node);
	of_node_put(node);
	if (!pdev)
		return -ENODEV;
	parent = pdev->dev.parent;
	if (!parent)
		goto put;

	device_lock(parent);
	device_lock(&pdev->dev);
	if (pdev->dev.driver || !parent->driver ||
	    strcmp(parent->driver->name, "pmic-spmi") ||
	    !of_device_is_compatible(parent->of_node, "qcom,pm8150") ||
	    of_property_read_u32(parent->of_node, "reg", &sid) || sid)
		goto unlock;
	map = dev_get_regmap(parent, NULL);
	if (!map)
		goto unlock;

	pr_info("np545-rtc-diag: begin device=%s parent=%s\n",
		dev_name(&pdev->dev), dev_name(parent));
	ret = regmap_read(map, 0x6046, &control);
	if (ret)
		goto unlock;
	ret = read_counter(map, &first);
	if (ret)
		goto unlock;
	before_ms = ktime_to_ms(ktime_get_boottime());
	msleep(1100);
	ret = read_counter(map, &second);
	if (ret)
		goto unlock;
	after_ms = ktime_to_ms(ktime_get_boottime());
	pr_info("np545-rtc-diag: ctrl=0x%02x first=%u second=%u delta=%u elapsed_ms=%lld\n",
		control, first, second, second - first, after_ms - before_ms);
	ret = regmap_read(map, 0x6146, &alarm_control);
	if (ret)
		goto unlock;
	ret = regmap_bulk_read(map, 0x6140, alarm, sizeof(alarm));
	if (ret)
		goto unlock;
	pr_info("np545-rtc-diag: alarm_ctrl=0x%02x alarm_raw=%u complete\n",
		alarm_control, get_unaligned_le32(alarm));
unlock:
	if (ret)
		pr_info("np545-rtc-diag: stopped error=%d\n", ret);
	device_unlock(&pdev->dev);
	device_unlock(parent);
put:
	put_device(&pdev->dev);
	return ret;
}

static void __exit np545_rtc_diag_exit(void)
{
}

module_init(np545_rtc_diag_init);
module_exit(np545_rtc_diag_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("One-shot read-only NP545XLA PMIC RTC diagnostic");
