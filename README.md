
线上VPC的微信负载配置
---



增加功能：
- 缓存机制，支持openresty和redis双缓存
- 根据指定openid查询对应路由URL的api
- 增加接收各个vpc服务端推送的json数据


### 部署
1、安装redis服务端，使两个Openresty服务端能访问，注意需设置redis的访问密码
2、修改nginx配置文件nginx.conf，增加支持cache的配置项：
```
lua_shared_dict openids 128m;
```
3、将wechat.conf和wechat.lua文件放置到$OPENRESTY_HOME/nginx/conf/conf.d/目录下
4、修改wechat.lua脚本中的redis配置
redis 相关配置见wechat.lua脚本第24-30行：
```lua
local ok, err = red:connect("REDIS服务ip", 端口)
if not ok then
    ngx.log(ngx.ERR, "failed to connect: ", err)
    return
end
local res, err = red:auth("密码")
if not res then
    ngx.log(ngx.ERR, "failed to authenticate: ", err)
    return
end
```



### 推送和跟踪

##### VPC各服务端推送自己对应的openid列表：

发送POST请求/api/push，请求体json格式：

```json
{"url":"http://......", "openids": ["gh_example1", "gh_example2", "gh_example3"]}
```



##### 调试跟踪指定openid跳转到的VPC：

发送GET请求/api/openid/微信的openid，如：

```shell
http://...../api/openid/gh_example1
```

> 注：目前查询仅限通过推送存储到redis及缓存中的对应关系。原逻辑暂未输出映射。



### 备注

当前项目处于测试阶段，请大力测试，可在[Issue](http://git.xiaoneng.cn/fengxu/wechat.conf/issues)提出意见。

