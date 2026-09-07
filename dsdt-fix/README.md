# dsdt-fix — 各固件版本的 DSDT 覆盖补丁

按 BIOS 版本分目录。每个目录包含该固件对应的：

- `dsdt.aml` — 编译好的覆盖表（安装用）
- `dsdt.dsl` — 补丁后的反汇编源码
- `dsdt-original.dsl` / `dsdt-original.dat` — 原始表备份
- `patch.diff` — 补丁差异（附每处问题/原理/出处）
- `README.md` — 该版本的说明

## 目录

| 目录 | 状态 |
|---|---|
| `F.29/` | ✅ 真实补丁（HP OMEN Transcend 16-u1024TX / 板 8C4D / BIOS F.29） |
| `F.28/` | ⚠️ **FAKE**，仅供测试路由，内容等同 F.29，勿当真实补丁 |

## 路由

根目录的 `install.sh` 会自动读取本机 BIOS 版本，去 `dsdt-fix/<BIOS>/dsdt.aml`
下载对应补丁；没有精确匹配时会列出本目录里已有的版本让你选。
