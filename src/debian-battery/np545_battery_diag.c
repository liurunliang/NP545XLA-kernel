// SPDX-License-Identifier: GPL-2.0
// One-shot, read-only inspection of the existing NP545XLA SBS client.
// No driver binding, workqueue, client flag changes or register writes.
#include <linux/ctype.h>
#include <linux/i2c.h>
#include <linux/module.h>
#include <linux/of.h>

static bool strings;
module_param(strings, bool, 0444);
MODULE_PARM_DESC(strings, "Also read standard SBS manufacturer, model and chemistry blocks");

static int read_string(struct i2c_client *client, u8 reg, char *text)
{
	u8 data[I2C_SMBUS_BLOCK_MAX];
	int len, ret, i;

	if (i2c_check_functionality(client->adapter,
				    I2C_FUNC_SMBUS_READ_BLOCK_DATA)) {
		len = i2c_smbus_read_block_data(client, reg, data);
		if (len < 0)
			return len;
		if (!len || len > I2C_SMBUS_BLOCK_MAX)
			return -EPROTO;
	} else {
		/* Same two-read protocol as sbs-battery.c, without changing PEC. */
		if (!i2c_check_functionality(client->adapter,
			I2C_FUNC_SMBUS_READ_BYTE_DATA | I2C_FUNC_SMBUS_READ_I2C_BLOCK))
			return -EOPNOTSUPP;
		len = i2c_smbus_read_byte_data(client, reg);
		if (len < 0)
			return len;
		/* The length byte must also fit the 32-byte I2C block helper. */
		if (!len || len >= I2C_SMBUS_BLOCK_MAX)
			return -EMSGSIZE;
		ret = i2c_smbus_read_i2c_block_data(client, reg, len + 1, data);
		if (ret < 0)
			return ret;
		if (ret != len + 1 || data[0] != len)
			return -EPROTO;
		memmove(data, data + 1, len);
	}
	for (i = 0; i < len; i++)
		text[i] = isprint(data[i]) ? data[i] : '?';
	text[len] = '\0';
	return len;
}

static int __init np545_battery_diag_init(void)
{
	static const u8 words[] = { 0x03, 0x1a, 0x08, 0x14, 0x15, 0x16, 0x19 };
	struct device_node *node;
	struct i2c_client *client;
	char text[I2C_SMBUS_BLOCK_MAX + 1];
	int i, ret = 0;

	if (!of_machine_is_compatible("samsung,np545xla"))
		return -ENODEV;
	node = of_find_node_by_path("/soc@0/geniqup@cc0000/i2c@c88000/battery@b");
	if (!node)
		return -ENODEV;
	client = of_find_i2c_device_by_node(node);
	of_node_put(node);
	if (!client)
		return -ENODEV;
	device_lock(&client->dev);
	if (client->addr != 0x0b || client->flags || !client->dev.driver ||
	    strcmp(client->dev.driver->name, "np545-battery-ro") ||
	    !i2c_check_functionality(client->adapter, I2C_FUNC_SMBUS_READ_WORD_DATA)) {
		ret = -ENODEV;
		goto out;
	}
	pr_info("np545-battery-diag: begin client=%s strings=%d\n",
		dev_name(&client->dev), strings);
	for (i = 0; i < ARRAY_SIZE(words); i++) {
		int value = i2c_smbus_read_word_data(client, words[i]);

		if (value < 0) {
			ret = value;
			pr_info("np545-battery-diag: reg=0x%02x error=%d\n", words[i], ret);
			goto out;
		}
		pr_info("np545-battery-diag: reg=0x%02x word=0x%04x decimal=%d\n",
			words[i], value, value);
	}
	if (strings) {
		for (i = 0x20; i <= 0x22; i++) {
			ret = read_string(client, i, text);
			if (ret < 0) {
				pr_info("np545-battery-diag: reg=0x%02x error=%d\n", i, ret);
				goto out;
			}
			pr_info("np545-battery-diag: reg=0x%02x length=%d text=%s\n",
				i, ret, text);
		}
	}
	ret = 0;
	pr_info("np545-battery-diag: complete\n");
out:
	device_unlock(&client->dev);
	put_device(&client->dev);
	return ret;
}

static void __exit np545_battery_diag_exit(void)
{
}

module_init(np545_battery_diag_init);
module_exit(np545_battery_diag_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("One-shot read-only NP545XLA SBS identity and mode diagnostic");
