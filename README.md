# 背景

[Julia](http://julialang.org/) 是一种高性能的数学计算型语言，它有着类似 matlab，R 的语法，但运行速度却能和 C 达到一个数量级，本代码示例了如何在 Julia 中使用 DzhYun 里的数据进行数学运算。

本示例配合使用 [dzhyunsdk](https://github.com/elsejj/dzhyunsdk/) 使用更佳，因为 sdk 能提供性能更好的数据连接

本示例中的 Websocket.jl 修改自 [JuliaWeb](https://github.com/JuliaWeb/WebSockets.jl) , 为其增加了客户端连接的特性，原 WebSockets.jl 只支持作为服务器使用
