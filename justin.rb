begin
  require 'rubygems'
rescue LoadError
end
begin
  require 'oauth'
rescue LoadError
  error 'OAuth module could not be loaded'
end
require 'webrick'

class JustinPlugin < Plugin
  attr_accessor :reg
  
  Config.register(Config::IntegerValue.new('justin.server_port',
    :default => 7207,
    :desc => 'Port to use for the callback http server.'))
  Config.register(Config::StringValue.new('justin.server_host',
    :default => 'example.com',
    :desc => 'Host/ip the port is publicly availible.'))
  Config.register(Config::StringValue.new('justin.server_bind',
    :default => '0.0.0.0',
    :desc => 'Bind host the http server listens on.'))
  Config.register(Config::StringValue.new('justin.oauth_key',
    :default => nil,
    :desc => 'OAuth Consumer Key'))
  Config.register(Config::StringValue.new('justin.oauth_secret',
    :default => nil,
    :desc => 'OAuth Consumer Secret'))
  Config.register(Config::ArrayValue.new('justin.announce_dst',
    :default => [],
    :desc => 'A list of channel to announce up callbacks'))
  
  include WEBrick
  
  def help(topic)
    return 'justin.tv rbot plugin: justin status|authorize|deauthorize|show|watch|unwatch'
  end
  
  def initialize
    super
    if @registry.has_key?(:justin)
      debug 'load registry'
      @reg = @registry[:justin]
      raise LoadError, "corrupted justin.tv database" unless @reg
    else
      debug 'reset registry'
      @reg = Hash.new
    end

    bind = @bot.config['justin.server_bind']
    host = @bot.config['justin.server_host']
    port = @bot.config['justin.server_port']
    @callback_url = "http://#{host}:#{port}/callback"

    @http_server = HTTPServer.new(:Port => port, :BindAddress => bind)
    @http_server.mount_proc('/') do |request, response|
      message = 'server ready'
      @bot.say('#sixtest', request.request_method+' '+request.path)
      if request.path == '/callback'
        @bot.say('#sixtest', 'query: '+request.query.inspect)
        if request.query.has_key? 'oauth_token'
          # request access token
          token = request.query['oauth_token']
          
          if not @reg.has_key? 'oauth_request_' + token
            raise HTTPStatus::ServerError
          end

          oauth_request = YAML::load(@reg['oauth_request_' + token])
          begin
            access_token = oauth_request[:token].get_access_token
          rescue
            raise HTTPStatus::ServerError
          end
          @reg.delete('oauth_request_' + token)
          
          @reg['oauth_access_' + oauth_request[:nick]] = YAML::dump(access_token)
          @bot.say(oauth_request[:nick], 'justin.tv authorization success!')
          response['content-type'] = 'text/plain'
          response.body = "justin rbot plugin authorized for your account #{oauth_request[:nick]}\n"
          raise HTTPStatus::OK
        end # oauth access key
        
        if request.query.has_key? 'event' and request.query['event'] == 'stream_up'
          @bot.config['justin.announce_dst'].each do |dst|
            @bot.say(dst, "channel goes live: http://justin.tv/#{request.query['channel']} (stream_name:#{request.query['stream_name']})")
          end
          
          
        end
        
        
        
      end 
      
      
      
      # default response:
      response['content-type'] = 'text/plain'
      response.body = "justin rbot plugin running http server\n"
      raise HTTPStatus::OK
    end
    
    Thread.new do
      @http_server.start
    end
  end

  def save
    debug "save #{@reg.class} registry objects: #{@reg.inspect}"
    @registry[:justin] = @reg
  end

  def cleanup
    @http_server.shutdown if @http_server
    super
  end

  def status(m, params)
    m.reply 'callback server: '+@callback_url
    m.reply 'debug: registry: '+@reg.keys.inspect
  end
  
  def authorize(m, params)
    key = @bot.config['justin.oauth_key']
    secret = @bot.config['justin.oauth_secret']
    if not key or not secret
      m.reply 'no consumer oauth key or secret set'
      return false
    end

    #remove all old authorization data
    if @reg.has_key?('oauth_access_' + m.sourcenick)
      @reg.delete('oauth_access_' + m.sourcenick)
    end
    
    @consumer = OAuth::Consumer.new(key, secret, {
      :site => "http://api.justin.tv",
      :request_token_path => "/oauth/request_token",
      :access_token_path => "/oauth/access_token",
      :authorize_path => "/oauth/authorize"
    })
    begin
      request_token = @consumer.get_request_token
    rescue OAuth::Unauthorized
      m.reply 'blocked oauth authorization, wrong consumer key/secret?'
      return false
    end
    oauth_request = {
      :token => request_token,
      :nick => m.sourcenick
    }
    @reg['oauth_request_' + request_token.token] = YAML::dump(oauth_request)
    m.reply 'visit this url to authorize: ' + request_token.authorize_url
  end
  
  def deauthorize(m, params)
    @reg.each_key do |key|
      if key == 'oauth_access_' + m.sourcenick or
         (@reg[key].class != String and 
          @reg[key].has_key?(:nick) and 
          @reg[key][:nick] == m.sourcenick)
      
        m.reply('delete key: '+key) #TODO: debug: remove
        @reg.delete(key)
      end
    end
    m.okay
  end
  
  
  
  def callback_unwatch(m, params)
    access = YAML::load(@reg['oauth_access_' + m.sourcenick])
    channel = m.sourcenick
    channel = params[:channel] if params.has_key? :channel
    
    begin
      response = access.post('http://api.justin.tv/api/stream/unregister_callback.json', {
        :event => 'stream_up', 
        :channel => channel, 
        :callback_url => @callback_url})
    rescue
      m.reply 'something gone wrong'
    end
    m.reply 'not longer watching for '+channel+' to go online: '+response.inspect
  end
  
  def callback_watch(m, params)
    access = YAML::load(@reg['oauth_access_' + m.sourcenick])
    channel = m.sourcenick
    channel = params[:channel] if params.has_key? :channel
    
    begin
      response = access.post('http://api.justin.tv/api/stream/register_callback.json', {
        :event => 'stream_up', 
        :channel => channel, 
        :callback_url => @callback_url})
    rescue
      m.reply 'something gone wrong'
    end
    m.reply 'watching for '+channel+' to go online: '+response.inspect
  end
  
  def callback_list(m, params)
    access = YAML::load(@reg['oauth_access_' + m.sourcenick])
    channel = m.sourcenick
    channel = params[:channel] if params.has_key? :channel

    begin
      response = access.get("http://api.justin.tv/api/stream/list_callbacks.json?channel=#{channel}")
    rescue
      m.reply 'something gone wrong'
    end
    m.reply 'callbacks for '+channel+': '+response.inspect
    
  end
end
plugin = JustinPlugin.new
plugin.map('justin status', :action => 'status')

plugin.map('justin authorize', :action => 'authorize', :public => false)
plugin.map('justin deauthorize', :action => 'deauthorize', :public => false)

plugin.map('justin list [:channel]', :action => 'callback_list')
plugin.map('justin watch [:channel]', :action => 'callback_watch')
plugin.map('justin unwatch [:channel]', :action => 'callback_unwatch')



