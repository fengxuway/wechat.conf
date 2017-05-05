local hosts_get = {'http://192.168.30.234:80'}
local hosts_post = {'http://192.168.30.234:80'}
local hosts_nginx = {'http://192.168.30.213', 'http://192.168.31.245'}


function get_from_cache(key)
    local cache_ngx = ngx.shared.openids
    local value = cache_ngx:get(key)
    return value
end

function set_to_cache(key, value, exptime)
    if not exptime then
        exptime = 0
    end
    local cache_ngx = ngx.shared.openids
    local succ, err, forcible = cache_ngx:set(key, value, exptime)
    return succ
end

function get_keys()
    return ngx.shared.openids:get_keys()
end

function redis_connect()
    local redis = require "resty.redis"
    local red = redis:new()
    red:set_timeout(1000)
    local ok, err = red:connect("127.0.0.1", 6374)
    if not ok then
        ngx.log(ngx.ERR, "failed to connect: ", err)
        return
    end
    local res, err = red:auth("rediS")
    if not res then
        ngx.log(ngx.ERR, "failed to authenticate: ", err)
        return
    end
    return red
end
-- redis中key的前缀
local red_prefix = "openresty_openid_"
-- redis缓存的时间 200秒，线上一小时零5分钟
local expiretime_redis = 4000
-- openresty的缓存时间60秒，线上16分钟
local expiretime = 1000     
function get_wechatid_route(wechatid)
    ngx.log(ngx.INFO, "get_wechatid_route: [",wechatid,"]")
    url = get_from_cache(wechatid)
    if url == nil then
        ngx.log(ngx.WARN, "openresty cache not found")
        if table.getn(get_keys()) == 0 then

            ngx.log(ngx.INFO, "load from redis...")
            red = redis_connect()
            local all_keys = red:keys(red_prefix.."*")
            for i, k in ipairs(all_keys) do
                local v = red:get(k)
                local sub_k = string.sub(k,string.len(red_prefix)+1, string.len(k))
                set_to_cache(sub_k, v, expiretime)
                ngx.log(ngx.INFO, "set to cache: Key: [", sub_k, "] Value: [",v,"]")
            end
            red:close()
            return get_from_cache(wechatid)
        else
            ngx.log(ngx.WARN, "Has another key, don't update from redis")
            return url
        end
    else
        return url
    end
    
end


function sync(body)
    local http = require "resty.http"  
    local httpc = http.new()
    for i, k in ipairs(hosts_nginx) do
         local res, err = httpc:request_uri(k..'/api/sync', {  
            method = "POST",  
            --args = str,  
            body = body,  
            headers = {  
                ["Content-Type"] = "application/json",  
            }  
        })
        if not res then  
            ngx.log(ngx.WARN,"failed to request: ", err)  
        end
    end
end
       

local request_method = ngx.var.request_method

local uri = ngx.var.request_uri
--ngx.say(uri)
ngx.log(ngx.ERR, uri)
local regex_url = [[/callback/(\w+)]]
local match_url = ngx.re.match(uri, regex_url, "o")

local api_regex_url = [[/api/openid/(\w+)]]
local api_match_url = ngx.re.match(uri, api_regex_url, "o")

ngx.var.target = hosts_get[1]



if match_url then

    local wechatid = match_url[1]
    target_url = get_wechatid_route(wechatid)
    ngx.log(ngx.INFO, "--url: ", target_url)

    if target_url ~= nil then
        -- 如果存在，跳转到对应缓存中的url
        ngx.var.target = target_url
        ngx.log(ngx.INFO, "["..wechatid.."] ===> ", target_url)
    else
        local ascii = 0
        len = string.len(wechatid) 
        for i = 1, len do
            ascii = ascii + string.byte(wechatid, i)
        end
        mod = ascii % table.getn(hosts_get) + 1
        ngx.var.target = hosts_get[mod]
        ngx.log(ngx.INFO, "["..wechatid.."] ===> ", hosts_get[mod])
    end
elseif request_method == "POST" then 
    ngx.req.read_body()

    ngx.log(ngx.INFO, "POST data comming")
    -- 获取各个vpc推送上来的json数据，并写入缓存和redis中
    if uri == "/api/push" then
        ngx.log(ngx.INFO, "ready to push data")
        local body = ngx.req.get_body_data()
        local cjson = require "cjson"
        local data = cjson.decode(body);

        red = redis_connect()

        for i,v in ipairs(data["openids"]) do
            set_to_cache(v, data["url"], expiretime)
            local res, err = red:set(red_prefix..v, data["url"])
            if not res then
                ngx.log(ngx.ERR, "failed to set: ", err)
                return
            end
            red:expire(red_prefix..v, expiretime_redis)
        end
        red:close()

        sync(body)

        ngx.log(ngx.INFO, "Push Success")
        ngx.say("Push success!")
        ngx.exit(200)
        return
    end

    if uri == "/api/sync" then
        local body = ngx.req.get_body_data()
        ngx.log(ngx.INFO, body)
        local cjson = require "cjson"
        local data = cjson.decode(body);
        for i,v in ipairs(data["openids"]) do
            set_to_cache(v, data["url"], expiretime)
            ngx.log(ngx.INFO, v, data['url'])
        end
        ngx.exit(200)
        return
    end

    local data = ngx.req.get_body_data()
    local regex_body = [[<FromUserName>(.*?)</FromUserName>]]
    local touser_regex_body = [[<ToUserName>(.*?)</ToUserName>]]
    local match_body = ngx.re.match(data, regex_body, "o")
    local touser_match_body = ngx.re.match(data, touser_regex_body, "o")
    if touser_match_body then
        username = touser_match_body[1]
        -- 如果username被CDATA包裹，则获取其内部的wechatid
        local match_wechatid = ngx.re.match(username, [[<!\[CDATA\[([\w-]+)\]\]>]], "o")
        local wechatid = nil
        if match_wechatid then
            wechatid = match_wechatid[1]
        else
            wechatid = username
        end
        ngx.log(ngx.INFO, "--wechatid: ", wechatid)

        -- 查找缓存中的wechatid是否存在
        target_url = get_wechatid_route(wechatid)
        ngx.log(ngx.INFO, "--url: ", target_url)

        
        if target_url ~= nil then
            -- 如果存在，跳转到对应缓存中的url
            ngx.var.target = target_url
            ngx.log(ngx.INFO, "["..wechatid.."] ===> ", target_url)
            --ngx.say("["..wechatid.."] ===> ", target_url)
        else
            ngx.log(ngx.WARN, "wechatid ["..wechatid.."] not in Cache!")
            if match_body then
                username = match_body[1]
                ngx.log(ngx.WARN, "wechatid ["..wechatid.."] not in Cache!")
                ngx.log(ngx.WARN, "According to FromUserName ["..username.."] Ascii code to random!")
                -- 缓存中不存在指定wechatid，则执行原来的逻辑
                local ascii = 0
                len = string.len(username) 
                for i = 1, len do
                    ascii = ascii + string.byte(username, i)
                end
                mod = ascii % table.getn(hosts_post) + 1
                ngx.var.target = hosts_post[mod]
                ngx.log(ngx.INFO, "["..username.."] ===> ", hosts_post[mod])
            else
                ngx.var.target = hosts_post[1]
                ngx.log(ngx.INFO, "["..username.."] ===> ", hosts_post[mod])
                
            end
        end    
    else
        ngx.var.target = hosts_post[1]
        ngx.log(ngx.INFO, "turn to ===> ", hosts_post[1])
    end
elseif api_match_url then
    ngx.log(ngx.INFO, "API get wechatid bind URL")
    -- 提供api获取指定wechatid对应的路由url
    local wechatid = api_match_url[1]
    url = get_wechatid_route(wechatid)
    if url == nil then
        ngx.say("WechatID: ["..wechatid.."] Not found!")
    else
        ngx.say(url)
    end
    ngx.exit(200)
else
    ngx.var.target = hosts_post[1]
end
