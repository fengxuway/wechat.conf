local hosts_get = {'http://192.168.30.234:80'}
local hosts_post = {'http://1.1.1.1', 'http://2.2.2.2', 'http://3.3.3.3','http://4.4.4.4'}
local hosts_nginx = {'http://10.0.0.120', 'http://10.0.0.121'}

local redis_server = '192.168.90.223'
local redis_port = 6379
local redis_password = 'rediS'

-- redis缓存的时间 200秒，线上一小时零5分钟，也就是4000秒
local expiretime_redis = 4000
-- openresty的缓存时间60秒，线上一年, 约等于2592000
local expiretime = 1000     



function get_from_cache(key)
    -- 读取nginx缓存的数据
    return ngx.shared.openids:get(key)
end

function set_to_cache(key, value, exptime)
    -- 将key和value写入缓存，过期时间为exptime
    if not exptime then
        exptime = 0
    end
    
    local cache_ngx = ngx.shared.openids
    local succ, err, forcible = cache_ngx:set(key, value, exptime)
    return succ
end

function delete_from_cache(key)
    -- 从缓存中删除指定的值
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
    -- 如字符串“abc”，返回值为97+98+99之和
    local ascii = 0
    len = string.len(wechatid) 
    for i = 1, len do
        ascii = ascii + string.byte(wechatid, i)
    end
    return ascii
end

function json_decode(str)
    -- 异常捕获 json解析
    -- 建议用这种方式代替cjson.decode直接调用，如果解析异常可捕获
    local cjson = require "cjson"
    local data = nil
    _, err = pcall(function(str) return cjson.decode(str) end, str)
    if _ then
        return err
    end
    return nil
end

function redis_connect()
    -- redis连接操作，如果连接成功，返回redis连接对象
    local redis = require "resty.redis"
    local red = redis:new()
    red:set_timeout(1000)
    local ok, err = red:connect(redis_server, redis_port)
    if not ok then
        ngx.log(ngx.ERR, "failed to connect: ", err)
        return
    end
    -- 认证redis（redis需设置密码，否则lua库无法连接）
    local res, err = red:auth(redis_password)
    if not res then
        ngx.log(ngx.ERR, "failed to authenticate: ", err)
        return
    end
    return red
end
-- redis中key的前缀（以便于区分其他应用的key）
local red_prefix = "openresty_openid_"
function get_wechatid_route(wechatid)
    -- 根据wechatid获取对应的URL

    ngx.log(ngx.INFO, "get_wechatid_route: [",wechatid,"]")
    -- 首先从nginx缓存中读取
    url = get_from_cache(wechatid)
    if url == nil then
        -- 如果nginx缓存中没有，那么检测nginx中是不是没有缓存
        -- 如果没有缓存说明该nginx实例刚刚启动
        -- 这时连接redis拷贝所有的缓存写入本地
        ngx.log(ngx.WARN, "openresty cache not found")
        if table.getn(get_keys()) == 0 then
    
            ngx.log(ngx.INFO, "load from redis...")
            red = redis_connect()
            -- 读取redis中所有的缓存并遍历写入nginx缓存
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
    -- 同步函数，向所有的nginx节点发送刚刚提交或删除的数据
    local http = require "resty.http"  
    local httpc = http.new()
    -- 遍历hosts_nginx并向它发送请求
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

-- 请求类型 GET or POST等
local request_method = ngx.var.request_method

-- 请求URL，以/开头
local uri = ngx.var.request_uri
--ngx.say(uri)
ngx.log(ngx.ERR, uri)

-- 默认的跳转目标，不过没什么用，防止逻辑漏掉
ngx.var.target = hosts_get[1]

if request_method == "POST" then
    -- 如果是POST请求，尝试读取body，提高ngx.req.get_body_data()获取请求体的成功率
    ngx.req.read_body()
end

----------------------------- api相关 start ----------------------------

-- 获取各个vpc推送上来的json数据，并写入缓存和redis中
if uri == "/api/push" then
    -- 请求体结构：{"openids": ["gh_111111", "gh_22222"], "url": "http://bj-v1.ntalker.com"}
    ngx.log(ngx.INFO, "ready to push data")
    local body = ngx.req.get_body_data()
    local data = json_decode(body)
    if data == nil then
        -- 判断json格式是否有误
        ngx.say("Json format error!")
        ngx.exit(500)
    end

    red = redis_connect()
    -- 遍历openids以"openid": "url"结构写入nginx和redis缓存
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
    -- 同步到其他nginx中
    sync(body)

    ngx.log(ngx.INFO, "Push Success")
    ngx.say("Push success!")
    ngx.exit(200)
    return
end

if uri == "/api/delete" then
    -- 删除一批openid
    -- 由于线上openid失效时间是一年，所以如果有迁移回滚情况，需要移除已上传的openid，访问该url即可
    -- body格式：{"openids": ["gh_111111", "gh_22222"]}
    ngx.log(ngx.INFO, "ready to delete cached data")
    local body = ngx.req.get_body_data()
    local data = json_decode(body)
    if data ~= nil then
        red = redis_connect()

        for i,v in ipairs(data["openids"]) do
            delete_from_cache(v)
            red:expire(red_prefix..v, 1)
        end
        red:close()
        -- 同步到其他nginx
        sync(body)

        ngx.log(ngx.INFO, "Push Success")
        ngx.say("Push success!")
    else
        ngx.say("Push Error! 请求体格式异常")
    end
    ngx.exit(200)
    return
end

if uri == "/api/sync" then
    -- 接收到来自其他nginx的同步请求
    local body = ngx.req.get_body_data()
    ngx.log(ngx.INFO, body)
    local data = json_decode(body)
    if data ~= nil then
        for i,v in ipairs(data["openids"]) do
            if data['url'] ~= nil then
                set_to_cache(v, data["url"], expiretime)
                ngx.log(ngx.INFO, 'synced', v, data['url'])
            else
                delete_from_cache(v)
                ngx.log(ngx.INFO, 'synced', v, 'deleted')
            end
            
        end
    end
    ngx.exit(200)
    return
end

-- 查询指定wechatid对应的url的接口
local api_regex_url = [[/api/openid/(\w+)]]
local api_match_url = ngx.re.match(uri, api_regex_url, "o")
if api_match_url then
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
end

----------------------------- api相关 end ------------------------------

----------------------------- 业务相关 start ----------------------------

function resolve_body_touser(body)
    -- 解析请求体中的ToUserName，如果缓存中存在则直接跳转
    -- 否则返回false
    local touser_regex_body = [[<ToUserName>(.*?)</ToUserName>]]
    local touser_match_body = ngx.re.match(body, touser_regex_body, "o")
    if touser_match_body then
        local username = touser_match_body[1]
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
            return true
        end
    end
    return false

end

function resolve_url_sdk(url)
    -- 解析如果url中存在openid，
    -- 缓存中存在openid，跳转到缓存的url
    -- 否则返回false
    local regex_weixin_sdk = [[/agent/weixin.*?[&\?]openid=([\w-]+)]]
    local match_weixin_sdk = ngx.re.match(uri, regex_weixin_sdk, "o")

    if match_weixin_sdk then
        -- 2017-08-08 新增，如果url包含/agent/weixin 并且有openid参数，直接根据openid的值路由
    
        local wechatid = match_weixin_sdk[1]
        ngx.log(ngx.INFO, "SDK request --wechatid: ", wechatid)

        -- 查找缓存中的wechatid是否存在        
        local target_url = get_wechatid_route(wechatid)
        if target_url ~= nil then
            -- 如果存在，跳转到对应缓存中的url
            ngx.var.target = target_url
            ngx.log(ngx.INFO, "["..wechatid.."] ===> ", target_url)
            --ngx.say("["..wechatid.."] ===> ", target_url)
            return true
        end
    end
    return false
end

function resolve_body_default(body)
    -- 解析body默认逻辑
    -- 如果存在FromUserName，那么解析计算ascii值，取模随机跳转到hosts_post对应的地址
    -- 否则直接跳转到hosts_post[1]地址
    local regex_body = [[<FromUserName>(.*?)</FromUserName>]]
    local match_body = ngx.re.match(body, regex_body, "o")
    if match_body then
        local username = match_body[1]
        ngx.log(ngx.WARN, "According to FromUserName ["..username.."] Ascii code to random!")
        -- 根据username的ascii之和随机分配
        local ascii = ascii_count(username)
        local mod = ascii % table.getn(hosts_post) + 1
        ngx.var.target = hosts_post[mod]
        ngx.log(ngx.INFO, "["..username.."] ===> ", hosts_post[mod])
    else
        ngx.var.target = hosts_post[1]
        ngx.log(ngx.INFO, "[ default ] ===> ", hosts_post[1])
    end
    return true
end



local regex_callback_url = [[/callback/(\w+)]]
local match_callback_url = ngx.re.match(uri, regex_callback_url, "o")

if match_callback_url then

    local wechatid = match_callback_url[1]
    target_url = get_wechatid_route(wechatid)
    ngx.log(ngx.INFO, "--url: ", target_url)
    
    if target_url ~= nil then
        -- 如果存在，跳转到对应缓存中的url
        ngx.var.target = target_url
        ngx.log(ngx.INFO, "["..wechatid.."] ===> ", target_url)
    else
        local ascii = ascii_count(wechatid)
        local mod = ascii % table.getn(hosts_get) + 1
        ngx.var.target = hosts_get[mod]
        ngx.log(ngx.INFO, "["..wechatid.."] ===> ", hosts_get[mod])
    end
elseif string.find(uri, '/agent/weibo') then
    ngx.log(ngx.INFO, "微博请求")
    -- 微博接口，判断/agent/weibo 将请求体json中的receiver_id 按缓存对应到VPC地址中
    -- 如果receiver_id不在缓存中，按sender_id的ASCII值随机到不同的节点上
    local data = ngx.req.get_body_data()
    local data_json = json_decode(data)
    if data_json == nil then
        -- 判断json格式是否有误
        -- 如果有误，直接跳转到hosts_post[1]
        ngx.log(ngx.WARN, "Json format error!", data)
        ngx.var.target = hosts_post[1]
        ngx.log(ngx.INFO, "[ weibo default ] turn to ===> ", hosts_post[1])
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

elseif string.find(uri, '/agent/weixin') then 

    local data = ngx.req.get_body_data()
        
    if resolve_body_touser(data) then
        -- 如果返回true，直接跳出lua程序
        return
    elseif resolve_url_sdk(uri) then
        return
    else
        return resolve_body_default(data)
    end
elseif string.find(uri, '/agent/xcx') then 

    local data = ngx.req.get_body_data()
        
    if resolve_body_touser(data) then
        -- 如果返回true，直接跳出lua程序
        return
    else
        return resolve_body_default(data)
    end
else
    ngx.var.target = hosts_post[1]
    ngx.log(ngx.INFO, "[ default ] ===> ", hosts_post[1])
end

