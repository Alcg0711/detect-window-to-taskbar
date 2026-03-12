# Detect Window to Taskbar

检测窗口到任务栏（OBS Lua 脚本）

## 功能

- 检测进程窗口，改为任务栏显示
- 支持手动检测或自动检测
- 查找窗口信息

## 说明

- 手动：手动检测一次窗口
- 自动：勾选自动，检测间隔结束会自动检测窗口
- 检测间隔(秒)：定时检测间隔时间
- 查找窗口信息：可在脚本日志显示process进程信息/Class类信息/Title标题信息）
- 匹配 Class/Title：只匹配 Class/Title 填写信息的窗口
- process 进程：每行一个，填写进程名称
- Class 类：每行一个，填写 Class 类名称
- Title 标题：每行一个，填写 Title 标题名称
