// SPDX-License-Identifier: GPL-2.0
// Read-only SBS telemetry for the optional Samsung NP545XLA device tree.
#include <linux/i2c.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/power_supply.h>
#include <linux/workqueue.h>

#define SBS_MODE             0x03
#define SBS_VOLTAGE          0x09
#define SBS_CURRENT          0x0a
#define SBS_SOC              0x0d
#define SBS_REMAINING        0x0f
#define SBS_FULL             0x10
#define SBS_REQUEST_CURRENT  0x14
#define SBS_REQUEST_VOLTAGE  0x15
#define SBS_STATUS           0x16
#define SBS_DESIGN_CAPACITY  0x18
#define SBS_DESIGN_VOLTAGE   0x19
#define SBS_SPEC_INFO        0x1a
#define SBS_ENERGY_MODE      BIT(15)
#define SBS_FULL_FLAG        BIT(5)

struct np545_battery {
	struct i2c_client *client;
	struct power_supply *supply;
	struct delayed_work refresh;
	int last_soc;
	int last_status;
};

static int word(struct np545_battery *bat, u8 reg)
{
	return i2c_smbus_read_word_data(bat->client, reg);
}

static int status(struct np545_battery *bat)
{
	int ma = word(bat, SBS_CURRENT);
	int flags;

	if (ma < 0)
		return ma;
	if ((s16)ma < 0)
		return POWER_SUPPLY_STATUS_DISCHARGING;
	if ((s16)ma > 0)
		return POWER_SUPPLY_STATUS_CHARGING;
	flags = word(bat, SBS_STATUS);
	if (flags < 0)
		return flags;
	return flags & SBS_FULL_FLAG ? POWER_SUPPLY_STATUS_FULL :
				       POWER_SUPPLY_STATUS_NOT_CHARGING;
}

static int capacity(struct np545_battery *bat, u8 reg, bool energy)
{
	int mode = word(bat, SBS_MODE);
	int raw, after;

	if (mode < 0)
		return mode;
	if (!!(mode & SBS_ENERGY_MODE) != energy)
		return -ENODATA;
	raw = word(bat, reg);
	if (raw < 0)
		return raw;
	after = word(bat, SBS_MODE);
	if (after < 0)
		return after;
	if ((after ^ mode) & SBS_ENERGY_MODE)
		return -EAGAIN;
	// Native units are mAh or 10 mWh. Never request a unit switch.
	return raw * (energy ? 10000 : 1000);
}

static enum power_supply_property properties[] = {
	POWER_SUPPLY_PROP_STATUS, POWER_SUPPLY_PROP_CAPACITY,
	POWER_SUPPLY_PROP_VOLTAGE_NOW, POWER_SUPPLY_PROP_VOLTAGE_MIN_DESIGN,
	POWER_SUPPLY_PROP_CURRENT_NOW, POWER_SUPPLY_PROP_CONSTANT_CHARGE_CURRENT_MAX,
	POWER_SUPPLY_PROP_CONSTANT_CHARGE_VOLTAGE_MAX, POWER_SUPPLY_PROP_CHARGE_NOW,
	POWER_SUPPLY_PROP_CHARGE_FULL, POWER_SUPPLY_PROP_CHARGE_FULL_DESIGN,
	POWER_SUPPLY_PROP_ENERGY_NOW, POWER_SUPPLY_PROP_ENERGY_FULL,
	POWER_SUPPLY_PROP_ENERGY_FULL_DESIGN, POWER_SUPPLY_PROP_PRESENT,
};

static int get_property(struct power_supply *psy, enum power_supply_property prop,
			union power_supply_propval *val)
{
	struct np545_battery *bat = power_supply_get_drvdata(psy);
	int raw;

	switch (prop) {
	case POWER_SUPPLY_PROP_STATUS:
		raw = status(bat);
		break;
	case POWER_SUPPLY_PROP_CAPACITY:
		raw = word(bat, SBS_SOC);
		if (raw > 100)
			return -ENODATA;
		break;
	case POWER_SUPPLY_PROP_PRESENT:
		raw = word(bat, SBS_VOLTAGE);
		if (raw >= 0)
			raw = raw > 0 && raw != 0xffff;
		break;
	case POWER_SUPPLY_PROP_VOLTAGE_NOW:
	case POWER_SUPPLY_PROP_VOLTAGE_MIN_DESIGN:
		raw = word(bat, prop == POWER_SUPPLY_PROP_VOLTAGE_NOW ?
				SBS_VOLTAGE : SBS_DESIGN_VOLTAGE);
		if (raw >= 0)
			raw *= 1000;
		break;
	case POWER_SUPPLY_PROP_CONSTANT_CHARGE_CURRENT_MAX:
	case POWER_SUPPLY_PROP_CONSTANT_CHARGE_VOLTAGE_MAX:
		raw = word(bat, prop == POWER_SUPPLY_PROP_CONSTANT_CHARGE_CURRENT_MAX ?
				SBS_REQUEST_CURRENT : SBS_REQUEST_VOLTAGE);
		if (raw == 0xffff)
			return -ENODATA;
		if (raw >= 0)
			raw *= 1000;
		break;
	case POWER_SUPPLY_PROP_CURRENT_NOW:
		raw = word(bat, SBS_CURRENT);
		if (raw < 0)
			return raw;
		val->intval = (s16)raw * 1000;
		return 0;
	case POWER_SUPPLY_PROP_CHARGE_NOW:
	case POWER_SUPPLY_PROP_ENERGY_NOW:
		raw = capacity(bat, SBS_REMAINING, prop == POWER_SUPPLY_PROP_ENERGY_NOW);
		break;
	case POWER_SUPPLY_PROP_CHARGE_FULL:
	case POWER_SUPPLY_PROP_ENERGY_FULL:
		raw = capacity(bat, SBS_FULL, prop == POWER_SUPPLY_PROP_ENERGY_FULL);
		break;
	case POWER_SUPPLY_PROP_CHARGE_FULL_DESIGN:
	case POWER_SUPPLY_PROP_ENERGY_FULL_DESIGN:
		raw = capacity(bat, SBS_DESIGN_CAPACITY, prop == POWER_SUPPLY_PROP_ENERGY_FULL_DESIGN);
		break;
	default:
		return -EINVAL;
	}
	if (raw < 0)
		return raw;
	val->intval = raw;
	return 0;
}

static const struct power_supply_desc supply_desc = {
	.name = "np545-battery",
	.type = POWER_SUPPLY_TYPE_BATTERY,
	.properties = properties,
	.num_properties = ARRAY_SIZE(properties),
	.get_property = get_property,
};

static void refresh(struct work_struct *work)
{
	struct np545_battery *bat = container_of(to_delayed_work(work), struct np545_battery, refresh);
	int soc = word(bat, SBS_SOC);
	int state = status(bat);

	if (soc >= 0 && soc <= 100 && state >= 0 &&
	    (soc != bat->last_soc || state != bat->last_status)) {
		bat->last_soc = soc;
		bat->last_status = state;
		power_supply_changed(bat->supply);
	}
	queue_delayed_work(system_freezable_wq, &bat->refresh, 10 * HZ);
}

static int np545_probe(struct i2c_client *client)
{
	struct power_supply_config cfg = { .fwnode = dev_fwnode(&client->dev) };
	struct np545_battery *bat;
	int spec, volts, soc;

	if (client->addr != 0x0b || !of_machine_is_compatible("samsung,np545xla") ||
	    !i2c_check_functionality(client->adapter, I2C_FUNC_SMBUS_READ_WORD_DATA))
		return -ENODEV;
	bat = devm_kzalloc(&client->dev, sizeof(*bat), GFP_KERNEL);
	if (!bat)
		return -ENOMEM;
	bat->client = client;
	spec = word(bat, SBS_SPEC_INFO);
	volts = word(bat, SBS_VOLTAGE);
	soc = word(bat, SBS_SOC);
	if (spec < 0 || volts < 0 || soc < 0)
		return dev_err_probe(&client->dev, min(spec, min(volts, soc)),
				     "cannot read SBS telemetry\n");
	// This board reports unscaled mV and mA. Reject an unfamiliar gauge.
	if ((spec & 0xff00) || !volts || volts == 0xffff || soc > 100)
		return dev_err_probe(&client->dev, -ENODEV, "unexpected SBS scale, voltage or SOC\n");
	cfg.drv_data = bat;
	bat->supply = devm_power_supply_register(&client->dev, &supply_desc, &cfg);
	if (IS_ERR(bat->supply))
		return PTR_ERR(bat->supply);
	i2c_set_clientdata(client, bat);
	bat->last_soc = -1;
	INIT_DELAYED_WORK(&bat->refresh, refresh);
	queue_delayed_work(system_freezable_wq, &bat->refresh, HZ);
	dev_info(&client->dev, "read-only SBS gauge: spec=%#x, %d mV, %d%%\n", spec, volts, soc);
	return 0;
}

static void np545_remove(struct i2c_client *client)
{
	struct np545_battery *bat = i2c_get_clientdata(client);

	cancel_delayed_work_sync(&bat->refresh);
}

static const struct of_device_id np545_of_match[] = {
	{ .compatible = "samsung,np545xla-battery-ro" }, {}
};
MODULE_DEVICE_TABLE(of, np545_of_match);

static struct i2c_driver np545_driver = {
	.driver = { .name = "np545-battery-ro", .of_match_table = np545_of_match },
	.probe = np545_probe,
	.remove = np545_remove,
};
module_i2c_driver(np545_driver);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Read-only NP545XLA smart battery telemetry");
