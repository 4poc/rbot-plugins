begin
  require 'rubygems'
rescue LoadError
end
require 'oauth'
require 'json'
require 'webrick'

class JustinPlugin < Plugin
  attr_accessor :reg

  API_SHOW = 'http://api.justin.tv/api/channel/show/%s.json'
  API_STREAMS_SUMMARY = 'http://api.justin.tv/api/stream/summary.json?channel=%s'
  API_REGISTER_CALLBACK = 'http://api.justin.tv/api/stream/register_callback.json'
  API_UNREGISTER_CALLBACK = 'http://api.justin.tv/api/stream/unregister_callback.json'
  API_CHANNEL_UPDATE = 'http://api.justin.tv/api/channel/update.json'

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
  Config.register(Config::BooleanValue.new('justin.ignore_iphone_stream',
    :default => true,
    :desc => 'Ignore iphone* stream names in callbacks'))
  Config.register(Config::BooleanValue.new('justin.show_include_description',
    :default => true,
    :desc => 'Include channel description in show'))
  Config.register(Config::BooleanValue.new('justin.show_include_about',
    :default => false,
    :desc => 'Include channel about text in show'))
  
  include WEBrick  

  def help(plugin,topic="")
    case topic
    when 'status'
      return 'justin status [message], update your channel status, you need to be authorized'
    when 'authorize'
      return 'justin authorize, login to your justin.tv account using oauth'
    when 'deauthorize'
      return 'justin deauthorize, remove the oauth access key'
    when 'show'
      return 'justin show [channel], show information about a specific channel'
    when 'watch'
      return 'justin watch [channel], register the channel for stream up/down callbacks'
    when 'unwatch'
      return 'justin unwatch [channel], removes the channel up/down callbacks'
    else
      return 'justin-rbot: justin status [message]|authorize|deauthorize|show [channel]|watch [channel]|unwatch [channel]'
    end
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
      if request.path == '/callback'
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
        
        # justin.tv up/down events
        if request.query.has_key? 'event'
          channel = request.query['channel']
          server_time = request.query['server_time']
          stream_name = request.query['stream_name']
          event = request.query['event']
          
          if @bot.config['justin.ignore_iphone_stream']
            if stream_name.include? 'iphone'
              raise HTTPStatus::OK
            end
          end
          
          last_callback_key = 'last_'+channel+'_callback_'+event
          if @reg.has_key? last_callback_key
            if (server_time.to_i - @reg[last_callback_key]) < 10 # sec.
              @reg[last_callback_key] = server_time.to_i
              raise HTTPStatus::OK
            end
          end
          @reg[last_callback_key] = server_time.to_i

          channel_info = nil
          begin
            channel_info = rest_request(nil, API_SHOW % channel)
          rescue Exception => e
          end
          
          message = "#{Bold}#{channel_info['title']}#{Bold} just went "
          if event == 'stream_up'
            message += "#{Bold}live#{Bold}"
          elsif event == 'stream_down'
            message += "#{Bold}offline#{Bold}"
          end
          
          if channel_info
            message += " '#{channel_info['status']}' on Justin.tv"
          end
          
          message += " (http://justin.tv/#{channel})"
          debug message
          debug stream_name
          
          # show the time between up and down events
          if event == 'stream_down'
            up_time = server_time.to_i - @reg['last_'+channel+'_callback_stream_up'].to_i
            message += ' [streamed for '+Utils.secs_to_string(up_time)+']'
          end
    
          @bot.config['justin.announce_dst'].each do |dst|
            @bot.say(dst, message)
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
  
  def callback_register(m, params)
    channel = m.sourcenick
    channel = params[:channel] if params.has_key? :channel
    
    begin
      post = {:channel => channel, :callback_url => @callback_url}
      response = rest_request(m.sourcenick, API_REGISTER_CALLBACK, post.merge({:event => 'stream_up'}))
      response = rest_request(m.sourcenick, API_REGISTER_CALLBACK, post.merge({:event => 'stream_down'}))
    rescue Exception => e
      m.reply e
      return false
    end
    m.reply 'watching for '+channel+' events'
  end
  
  def callback_unregister(m, params)
    channel = m.sourcenick
    channel = params[:channel] if params.has_key? :channel
    
    begin
      post = {:channel => channel, :callback_url => @callback_url}
      response = rest_request(m.sourcenick, API_UNREGISTER_CALLBACK, post.merge({:event => 'stream_up'}))
      response = rest_request(m.sourcenick, API_UNREGISTER_CALLBACK, post.merge({:event => 'stream_down'}))
    rescue Exception => e
      m.reply e
      return false
    end
    m.reply 'removed a callback for '+channel
  end
  

  def show(m, params)
    channel = m.sourcenick
    channel = params[:channel] if params.has_key? :channel

    begin
      response = rest_request(m.sourcenick, API_SHOW % channel)
    rescue Exception => e
      m.reply e
      return false
    end
    
    about = ''
    if response['about'] and not response['about'].empty? and @bot.config['justin.show_include_about']
      about = ' - ['+ response['about'].ircify_html + ']'
    end

    description = ''
    if response['description'] and not response['description'].empty? and @bot.config['justin.show_include_description']
      description = ' - ['+ response['description'].ircify_html + ']'
    end
    
    begin
      stats = rest_request(m.sourcenick, API_STREAMS_SUMMARY % channel)
    rescue Exception => e
      m.reply e
      return false
    end
    
    m.reply "#{Bold}#{response['title']}#{Bold}#{about}#{description} - #{response['status']} (http://justin.tv/#{response['login']}) (#{stats['viewers_count']} viewers)"
  end

  def update_status(m, params)
    message = params[:message]
    
    if not has_access(m, true)
      return false
    end
    begin
      post = {:status => message}
      response = rest_request(m.sourcenick, API_CHANNEL_UPDATE, post)
    rescue Exception => e
      m.reply e
      return false
    end
    m.okay
    
  end
  
  private
  
  def rest_request(sourcenick, url, post=nil)
    access = nil
    if sourcenick and @reg.has_key? 'oauth_access_' + sourcenick
      access = YAML::load(@reg['oauth_access_' + sourcenick])
    else
      # just use the first one
      @reg.each_key do |key|
        if key.include? 'oauth_access_'
          access = YAML::load(@reg[key])
          break
        end
      end
    end
    if not access
      raise 'no authorization'
      return false
    end
    
    begin
      if not post # GET
        response = access.get(url)
      else # POST
        response = access.post(url, post)
      end
    rescue
      raise 'oauth access exception'
    end
    
    if response.code.include? '30'
      debug response.get_fields('location').inspect
    end
    if response.code != '200'
      raise 'rest api invalid response code: '+response.code
    end
    
    return JSON::parse(response.body)
  end
  
  def has_access(m, reply=true)
    if @reg.has_key? 'oauth_access_' + m.sourcenick
      return true
    else
      m.reply 'you need to authorize' if reply
      return false
    end
  end
end
plugin = JustinPlugin.new
plugin.map('justin status', :action => 'status')

plugin.map('justin authorize', :action => 'authorize', :public => false)
plugin.map('justin deauthorize', :action => 'deauthorize', :public => false)

plugin.map('justin watch [:channel]', :action => 'callback_register')
plugin.map('justin unwatch [:channel]', :action => 'callback_unregister')

plugin.map('justin show [:channel]', :action => 'show')

plugin.map('justin status *message', :action => 'update_status')
