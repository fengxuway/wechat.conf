local hosts_get = {'http://192.168.30.234:80'}
local hosts_post = {'http://1.1.1.1', 'http://2.2.2.2', 'http://3.3.3.3','http://4.4.4.4'}
local hosts_nginx = {'http://10.0.0.120', 'http://10.0.0.122'}

local redis_server = '192.168.30.48'
local redis_port = 6379
local redis_password = 'rediS'

-- redis缓存的时间 200秒，线上一小时零5分钟，也就是4000秒
local expiretime_redis = 4000
-- openresty的缓存时间60秒，线上一年, 约等于2592000
local expiretime = 1000     



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

function delete_from_cache(key)
    local cache_ngx = ngx.shared.openids
    local succ, err, forcible = cache_ngx:delete(key)
    ngx.log(ngx.INFO, "delete_from_cache", key)
    return succ
end

function get_keys()
    return ngx.shared.openids:get_keys()
end

function ascii_count(wechatid)
    -- 计算一个字符串的每个字符串ascii总和，以便于随机
    local ascii = 0
    len = string.len(wechatid) 
    for i = 1, len do
        ascii = ascii + string.byte(wechatid, i)
    end
    return ascii
end

function redis_connect()
    local redis = require "resty.redis"
    local red = redis:new()
    red:set_timeout(1000)
    local ok, err = red:connect(redis_server, redis_port)
    if not ok then
        ngx.log(ngx.ERR, "failed to connect: ", err)
        return
    end
    local res, err = red:auth(redis_password)
    if not res then
        ngx.log(ngx.ERR, "failed to authenticate: ", err)
        return
    end
    return red
end
-- redis中key的前缀
local red_prefix = "openresty_openid_"
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
        if data == nil then
            -- 判断json格式是否有误
            ngx.say("Json format error!")
            ngx.exit(500)
        end

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

    if uri == "/api/delete" then
        ngx.log(ngx.INFO, "ready to delete cached data")
        local body = ngx.req.get_body_data()
        local cjson = require "cjson"
        local data = cjson.decode(body);

        red = redis_connect()

        for i,v in ipairs(data["openids"]) do
            delete_from_cache(v)
            red:expire(red_prefix..v, 1)
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
            if data['url'] ~= nil then
                set_to_cache(v, data["url"], expiretime)
                ngx.log(ngx.INFO, 'synced', v, data['url'])
            else
                delete_from_cache(v)
                ngx.log(ngx.INFO, 'synced', v, 'deleted')
            end
            
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
        local target_url = get_wechatid_route(wechatid)
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
    elseif string.find(uri, '/agent/weibo') then
        ngx.log(ngx.INFO, "微博请求")
        -- 微博接口，判断/agent/weibo 将请求体json中的receiver_id 按缓存对应到VPC地址中
        -- 如果receiver_id不在缓存中，按sender_id的ASCII值随机到不同的节点上
        local cjson = require "cjson"
        local data_json = cjson.decode(data);
        if data_json == nil then
            -- 判断json格式是否有误
            -- 如果有误，直接跳转到hosts_post[1]
            ngx.log(ngx.WARN, "Json format error!", data)
            ngx.var.target = hosts_post[1]
            ngx.log(ngx.INFO, "["..username.."] turn to ===> ", hosts_post[1])
        else
            local target_url = get_wechatid_route(data_json['receiver_id'])
            if target_url ~= nil then
                -- 如果存在，跳转到对应缓存中的url
                ngx.var.target = target_url
                ngx.log(ngx.INFO, "["..data_json['receiver_id'].."] ===> ", target_url)
                --ngx.say("["..wechatid.."] ===> ", target_url)
            else
                local sender_ascii = ascii_count(data_json['sender_id'])
                local mod = sender_ascii % table.getn(hosts_post) + 1
                ngx.var.target = hosts_post[mod]
                ngx.log(ngx.INFO, "["..data_json['receiver_id'].."] ===> ", hosts_post[mod])
            end
        end

    else
        ngx.var.target = hosts_post[1]
        ngx.log(ngx.INFO, "["..username.."] turn to ===> ", hosts_post[1])
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
    ngx.log(ngx.INFO, "["..username.."] ===> ", hosts_post[1])
end

