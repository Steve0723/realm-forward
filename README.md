# realm-forward

基于官方仓库 [zhboner/realm](https://github.com/zhboner/realm) 的交互式转发管理脚本。

## 功能

- 依赖检查，从 GitHub 官方 Release 安装或更新 Realm
- 添加、查看、删除转发规则
- 支持 TCP、UDP、TCP+UDP、WebSocket、WSS 和 TLS
- 加密类型可自由选择，支持自签名证书和自定义 PEM 证书
- 支持 systemd、OpenRC 和普通进程方式管理服务
- 支持健康检查和每日更新定时任务
- 查看日志和完全卸载

## 使用

```bash
chmod +x realm-forward.sh
./realm-forward.sh
```

脚本启动时只检查环境，不会自动下载或安装 Realm。进入主菜单后，请选择第 `1` 项手动安装或更新。

## 可选环境变量

```text
REALM_BIN=/usr/local/bin/realm
REALM_CONFIG_DIR=/etc/realm
REALM_LOG_FILE=/var/log/realm.log
REALM_PID_FILE=/var/run/realm.pid
REALM_INIT_SYSTEM=systemd|openrc|process
REALM_SKIP_CONFIG_TEST=1
```
