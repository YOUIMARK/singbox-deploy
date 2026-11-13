# singbox-deploy

## 📥 安装

```bash
bash <(wget -qO- https://raw.githubusercontent.com/YOUIMARK/singbox-deploy/main/install.sh || curl -fsSL https://raw.githubusercontent.com/YOUIMARK/singbox-deploy/main/install.sh)
```

**快捷命令:`sd`**(安装后输入 `sd` 唤出主菜单)

## 手动编辑配置

可以直接修改部署目录下的 `confs/config.json`。进入 DNS、分流或隧道设置时，脚本会先校验当前配置，自动同步规则、DNS、规则集和支持的隧道登记；配置变更事务也会自动识别这些手动修改，无需选择区域、规则位置或管理 ID。

主菜单的「检查配置」会校验、整理缩进并同步上述登记，不自动重载运行中的服务。规则插入、移动或删除按当前内容重新匹配，配置无效时保留原文件与登记并报告错误。手动规则集文件仍由用户维护，不因自动登记而取得目录清理权限。

主菜单可直接更新脚本；卸载仍使用独立入口。事务失败恢复由脚本自动处理。
