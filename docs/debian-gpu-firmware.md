# NP545XLA 的 Adreno ZAP 固件

三星 NP545XLA 的 Windows 显示驱动包含 `qcdxkmsuc8180.mbn`。本项目的设备树在 `qcom/sc8180x/SAMSUNG/NP545XLA/qcdxkmsuc8180.mbn` 查找它。发布的镜像和 Git 仓库仅保留提取方法与校验值。`a630_sqe.fw`、`a640_gmu.bin` 另取自 Debian。 [板级设备树](../dts/sc8180xp-samsung-np545xla.dts) · [Debian 固件提取脚本](../src/stage-adreno-firmware.sh)

## 这份文件如何对应到三星

本机 DSDT 的 `GPU0` 报告 `QCOM043A`、子系统 `C1A1144D`。仓库内另一台同型号机器的 Windows 记录显示 `REV_0913`、显示驱动 `27.20.1610.0`（2021-08-13）、安装节 `QCDX_Inst.NT`，DriverStore 目录为 `qcdx8180.inf_arm64_4063fa962c4df119`。 [Windows 硬件记录](dump/NP545XLA-hw-dump/hw-enum.txt)

以两份独立取得的驱动交叉校验。第一份是 tordona 发布的 **NP545XLA** 导出，其维护者说明来源为使用 OEM 恢复或安装介质的 Windows。第二份是 WOA Project 归档的高通参考机 `8180_CLS/200.0.64.0/qcdx8180.cab`。三星导出的 DriverStore 目录和 Windows 记录完全匹配。两份文件中的 INF、CAT 和 MBN 分别逐字节相同。INF 使用 `ACPI\VEN_QCOM&DEV_043A&REV_0913` 这一级兼容 ID 匹配三星，安装节和日期、版本均吻合。三星客服将这代 ARM 机型的驱动更新指向 Windows Update。 [NP545XLA 导出及发布哈希](https://github.com/tordona/woa-device-drivers/releases/tag/samsung-np545xla-drivers) · [参考机归档的固定版本](https://github.com/WOA-Project/Qualcomm-Reference-Drivers/blob/81bbe7ab8925e6d045f719711feeb01ed15deb50/8180_CLS/200.0.64.0/qcdx8180.cab) · [三星驱动支持](https://www.samsungsvc.co.kr/solution/40666)

| 文件 | SHA-256 |
| --- | --- |
| `NP545XLA.7z`（设备驱动导出） | `ec290dd56fc2844f48707751d769f6b425a8fa1cd7fdb56e5f3e4b4390900478` |
| `qcdx8180.cab`（参考机归档） | `2a594be549a3f1dc525775fee7ac222f260f8fbe91b52da731c84784b9957941` |
| `qcdx8180.inf` | `e4eca9f4f625404bd1c0ab98b726d847c3992beb5a1f75d2a14a3bc59bd05b94` |
| `qcdx8180.cat` | `488fa083af18e3cda2b246632fee1daf80dc20592f38fca53e36d45beda9a604` |
| `qcdxkmsuc8180.mbn`（14,240 字节） | `faaeac2c537e70053bf05b7ff6a7fb3462331c970dc55a7d2aa9fb5c4e8cc939` |

## 本机提取与验证

优先使用设备所有者已有的 Windows 驱动副本。如需从该机导出，在外部存储上准备一个空目录，在 Windows 管理员 PowerShell 中查看实际绑定的驱动、复制包并计算固件哈希。`oemNN.inf` 的数字由各自系统分配。 [微软 PnPUtil 文档](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/pnputil-command-syntax#export-driver)

```powershell
$gpu = Get-CimInstance Win32_PnPSignedDriver | Where-Object {
    $_.DeviceClass -eq 'DISPLAY' -and $_.DeviceID -like 'ACPI\VEN_QCOM&DEV_043A*'
}
$gpu | Select-Object DeviceName, DeviceID, InfName, DriverVersion
if (@($gpu).Count -ne 1) { throw 'Expected one QCOM043A display driver' }
$dest = Read-Host '已准备的外部存储空目录的完整路径'
pnputil /export-driver $gpu.InfName $dest
if ($LASTEXITCODE -ne 0) { throw 'Driver export failed' }
Get-ChildItem -LiteralPath $dest -Recurse -File -Filter qcdxkmsuc8180.mbn | Get-FileHash -Algorithm SHA256
```

安装了 Windows SDK 的机器可用 `signtool verify /v /pa /c qcdx8180.cat qcdxkmsuc8180.mbn` 再检查签名目录对固件文件的背书。也可在 Mac 或 Linux 上对上述三星导出重做提取，以下命令在存有压缩档的目录执行。 [微软的驱动目录验证步骤](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/verifying-the-signature-of-a-catalog-file-signed-by-a-commercial-relea)

```sh
printf '%s  %s\n' ec290dd56fc2844f48707751d769f6b425a8fa1cd7fdb56e5f3e4b4390900478 NP545XLA.7z | shasum -a 256 -c - &&
pkg=NP545XLA/qcdx8180.inf_arm64_4063fa962c4df119 &&
7z e -ooem NP545XLA.7z "$pkg/qcdx8180.inf" "$pkg/qcdx8180.cat" "$pkg/qcdxkmsuc8180.mbn" &&
printf '%s  %s\n' faaeac2c537e70053bf05b7ff6a7fb3462331c970dc55a7d2aa9fb5c4e8cc939 oem/qcdxkmsuc8180.mbn | shasum -a 256 -c -
```

本次使用 `osslsigncode` 验证 CAB、CAT 的 Authenticode 签名、微软时间戳和相应证书吊销列表。两者的签名者均为 `Microsoft Windows Hardware Compatibility Publisher`，签名链和时间戳链均验证至微软官方 `Microsoft Root Certificate Authority 2010`。时间戳为 2021-08-19 UTC。CAT 的同一条目同时包含 MBN 文件名和表中 SHA-256。 [微软 PKI 证书与吊销列表](https://www.microsoft.com/pkiops/docs/repository.htm)

MBN 为单文件 ELF32，唯一可加载段自文件偏移 `0x3000` 开始，大小 `0x7a0`，可重定位，按页计算为 4 KiB，设备树为它保留了 8 KiB。ELF 头、程序头及可加载段的 SHA-384 均符合内嵌哈希表，哈希表与元数据的 RSA-PSS/SHA-256 签名由叶证书验证通过。嵌入的链是 Qualcomm `CASS - SBL3` → `QMC Attestation CA 3 SubCA 1` → `QMC Attestation Root CA 3`。软件校验可以确认签名和字节来源。设备本身是否接受它，由正常的 Qualcomm SCM 加载路径决定。公开资料没有给出此三星固件的独立再分发许可，使用时保留原件及适用的厂商条款。 [Qualcomm 安全启动与固件认证说明](https://www.qualcomm.com/content/dam/qcomm-martech/dm-assets/documents/secure-boot-and-image-authentication.pdf)
