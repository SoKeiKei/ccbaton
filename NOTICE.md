# 致谢与第三方声明

## cc-switch

CCBaton 的"切换 Claude Code 登录"引擎（`Sources/Switcher.swift`）参考了
[cc-switch](https://github.com/farion1231/cc-switch) 公开源码里 `claude_account` 模块的设计思路
（账号槽位、把登录"移"进默认槽位、刷新锁、写后读回校验、日志与崩溃补完），用 Swift 重新实现。
cc-switch 以 MIT 许可发布，其许可声明如下：

```
MIT License

Copyright (c) 2025 Jason Young

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## 商标

"Claude"、"Claude Code" 是 Anthropic, PBC 的商标。CCBaton 是个人开发的非官方工具，
与 Anthropic 没有任何关联，也没有得到 Anthropic 的认可或背书。
