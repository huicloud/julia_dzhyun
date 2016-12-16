

using JSON

include("WebSockets.jl")

url = "http://127.0.0.1:9999/ws"


function my_handler(data)
    id = data["Data"]["Id"]
    if id == 20
        dynas = data["Data"]["RepDataQuoteDynaSingle"]
        for dyna in dynas
            println(dyna["Obj"], "\t", dyna["Data"]["ZuiXinJia"], "\t", dyna["Data"]["ChengJiaoLiang"])
        end
    end

end

function main(handler)
    ws = WebSocket(1, url)
    write(ws, "/quote/dyna?obj=SH600000,SH601519&sub=1")

    @async while true
        data = read(ws)
        handler(JSON.parse(String(data)))
    end

    while true
        line = strip(readline(STDIN))
        if strip(line) == "quit" 
            break
        end
        write(ws, line)
    end
end



main(my_handler)
