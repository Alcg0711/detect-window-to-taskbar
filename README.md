# Detect Window to Taskbar

检测窗口到任务栏（OBS Lua 脚本）

## 功能

- 检测指定进程窗口，将窗口改为任务栏显示
- 填写process名称/Class特征/Title特征
- 支持手动检测或自动检测
- 可选调试模式，打印匹配窗口信息
- 可选打印所有窗口，在脚本日志找到process名称/Class特征/Title特征信息

## 说明

- 手动检测：手动扫描一次窗口
- 自动检测：勾选自动检测，检测间隔结束会自动扫描窗口
- 检测间隔(秒)：定时扫描间隔
- 调试模式：打印匹配窗口信息
- 打印所有窗口：打印系统所有窗口信息（可在脚本日志找到process名称/Class特征/Title特征信息）
- Class/Title 特征：只处理匹配 Class 或 Title 的窗口
- process 名称：每行一个，填写进程名称
- Class 特征：每行一个，填写 Class 匹配
- Title 特征：每行一个，填写 Title 匹配
