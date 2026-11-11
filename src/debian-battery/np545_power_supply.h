/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef NP545_POWER_SUPPLY_H
#define NP545_POWER_SUPPLY_H

#include <linux/types.h>

/* Private reporting ABI, not a hardware control interface. Little endian. */
#define NP545_REPORT_VERSION 1
#define NP545_REPORT_ONLINE 1
#define NP545_REPORT_CONTRACT 2
#define NP545_REPORT_SETTINGS 4
#define NP545_REPORT_TTL_NS (20ULL * 1000000000ULL)

struct np545_report {
	__le32 version;
	__le32 valid;
	__le64 boottime_ns;
	__le32 online;
	__le32 voltage_max_uv;
	__le32 current_max_ua;
	__le32 input_limit_ua;
	__le32 charge_current_ua;
	__le32 charge_voltage_uv;
};

#endif
