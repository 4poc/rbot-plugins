# IMDb.com Search and Community Plugin

require 'method_profiler'

class EventManager
  def initialize
    @listeners = {}
    # alternativly allow to poll from a (global) queue:
    @queue = {}
  end

  def add(name, &block)
    if not @listeners.has_key? name
      @listeners[name] = []
    end
    @listeners[name] << block
  end

  def notify(name, obj)
    #debug 'notify listiners about event %s: ' % name
    #debug obj.inspect
    if @listeners.has_key? name
      @listeners[name].each do |block|
        block.call(obj)
      end
    end
    # add to poll/queue
    @queue[name] = [] unless @queue.has_key? name
    @queue[name] << obj
  end

  def poll(name)
    if @queue.has_key? name
      @queue.delete(name)
    else
      []
    end
  end
end

class ImdbNgPlugin < Plugin
  attr_accessor :users, :ratings, :imdb
  EXPORT_TICK = 25

  Config.register(Config::ArrayValue.new('imdbng.announce',
    :default => [],
    :desc => 'Channel announcements of ratings/watchlist.'))
  Config.register(Config::StringValue.new('imdbng.export_user',
    :default => nil,
    :desc => 'User (must exist!) to export csv with.'))

  def initialize
    super

    load File.dirname(__FILE__) + '/imdb2api/imdb2api.rb'

    @events = EventManager.new

    @imdb = IMDb::Api.new

    # store nickname, imdb-id, username, password
    @users = @registry.has_key?(:users) ? @registry[:users] : {}

    # ratings, stores known user ratings
    # [<imdb_id>] -> [ {:nick => ..., :user_id => ..., :rating => ...}, ... ]
    @ratings = @registry.has_key?(:ratings) ? @registry[:ratings] : {}
    # watchlist, stores users who have it on their watchlist
    # [<imdb_id>] -> [ {:nick => ..., :user_id => ...}, ... ]
    @watchlist = @registry.has_key?(:watchlist) ? @registry[:watchlist] : {}

    # timer every 3 minutes:
    @tick_timer = @bot.timer.add(60 * 2) do
      Thread.new do
        begin
          tick
          announce
        rescue
          error $!.to_s
          error $@.join '\n'
        end
      end
    end

    @ticks = 0
    @stats = {:export => false, :feed => false, :rating => 0, :new_rating => 0, :watchlist => 0, :new_watchlist => 0}
  end

  def save
    # cookies are not serializable, remove them:
    @users.each_pair do |nick, user|
      if user.has_key? :cookie
        user.delete(:cookie)
      end
    end
    @registry[:users] = @users if @users and @users.length > 0
    @registry[:ratings] = @ratings
    @registry[:watchlist] = @watchlist
  end

  def cleanup
    @bot.timer.remove(@tick_timer)
    super
  end

  def name
    'imdb-ng'
  end

  def tick
    @stats = {:export => false, :feed => false, :rating => 0, :new_rating => 0, :watchlist => 0, :new_watchlist => 0}
    # runs every n-minutes, every n-nth time we do a full scan (using csv-export)
    if (@ticks+1) % EXPORT_TICK == 0
      @stats[:export] = true
      update_export('ratings') { |nick, entries| update_ratings(nick, entries) }
      update_export('watchlist') { |nick, entries| update_watchlist(nick, entries) }
    else
      @stats[:feed] = true
      update_feed('ratings') { |nick, entries| update_ratings(nick, entries) }
      update_feed('watchlist') { |nick, entries| update_watchlist(nick, entries) }
    end

    @ticks += 1
  end

  def update_feed(type)
    # updates the ratings of every user
    @users.each_pair do |nick, user|
      debug 'update feed for user: %s' % [nick]
      user_id = user[:user_id]
      yield(nick, (@imdb.feed(user_id, type) or []))
    end
  end

  def update_export(type)
    export_user = @bot.config['imdbng.export_user']
    if not export_user or not login_as(export_user)
      error 'unable to export, unable to login as export user (not configured?)'
      return false
    end
    # updates the ratings of every user
    @users.each_pair do |nick, user|
      debug 'update export csv for user: %s' % [nick]
      user_id = user[:user_id]
      yield(nick, (@imdb.export(user_id, type) or []))
    end
  end

  def update_ratings(nick, ratings)
    debug 'update %d ratings' % ratings.length
    ratings.each do |rating|
      @stats[:rating] += 1
      imdb_id = rating[:imdb_id]
      # search for existing rating by this user:
      obj = get_user_from_list(@ratings, nick, imdb_id)
      if obj and obj[:rating].to_i == rating[:rating].to_i
        # exact same rating already exists
        next
      end
      if obj and obj[:rating].to_i != rating[:rating].to_i
        method = :update
        obj[:rating] = rating[:rating]
      else
        method = :create
        @ratings[imdb_id] = [] unless @ratings.has_key? imdb_id
        obj = {
          :nick => nick,
          :rating => rating[:rating]
        }
        @ratings[imdb_id] << obj
      end
      @stats[:new_rating] += 1
      @events.notify('rating', {:method => method, :imdb_id => imdb_id, :nick => nick, :rating => rating[:rating], :obj => obj})
    end
  end

  def update_watchlist(nick, watchlist)
    debug 'update %d watchlist' % watchlist.length
    watchlist.each do |entry|
      @stats[:watchlist] += 1
      imdb_id = entry[:imdb_id]
      # search for existing rating by this user:
      obj = get_user_from_list(@watchlist, nick, imdb_id)
      if obj
        # exact same watchlist entry
        next
      end

      method = :create
      @watchlist[imdb_id] = [] unless @watchlist.has_key? imdb_id
      obj = {
        :nick => nick
      }
      @watchlist[imdb_id] << obj

      @stats[:new_watchlist] += 1
      @events.notify('watchlist', {:method => method, :imdb_id => imdb_id, :nick => nick, :obj => obj})
    end
  end

  def get_user_from_list(list, nick, imdb_id)
    if list.has_key? imdb_id
      list[imdb_id].select { |entry|
        entry[:nick] == nick
      }.first
    end
  end

  def help(plugin, topic='')
    if topic == 'search'
      s = '[b]imdb[/c] [search] [b]<QUERY>[/c] : search IMDb.com by [b]<QUERY>[/c] and display first result.'
    elsif topic == 'tv'
      s = '[b]imdb[/c] tv [b]<QUERY>[/c] : search IMDb.com for TV Shows, return schedule information.'
    elsif topic == 'user'
      s = 'IMDb User Management: '
      s << '[b]imdb user [list][/c] : lists known users | '
      s << '[b]imdb user add <imdb-id>[/c] : create user with id | '
      s << '[b]imdb user login <username> <password>[/c] : login to rate movies | '
      s << '[b]imdb user remove[/c] : deletes your user information'
    else
      s = '[b]IMDb[/c] Plugin - Topics: [b]search[/c], [b]tv[/c], [b]user[/c] (read with [b]help imdb <topic>[/c])'
    end
    color_markup(s)
  end

  ###################################################################

  def search(m, params)
    return if params[:query].join(' ').include? 'login'
    entry = find_entry(m, params[:query].join(' '), :limit => 1) or return
    reply m, format_entry(entry, :overview, :plot)
  end

  def search_tv(m, params)
    entry = find_entry(m, params[:query].join(' '), :limit => 1, :load_series => true) or return
    reply m, format_entry(entry, :overview, :plot, :schedule)
  end

  def rate(m, params)
    entry = find_entry(m, params[:query].join(' '), :limit => 1)
    if not entry or entry.class >= IMDb::Title
      reply m, '[red]error movie not found'
      return
    end
    nick = m.source.to_s
    if not login_as(nick)
      reply m, '[red]unable to rate a movie[/c], you need to login first, [b]imdb login <username> <password>[/c] (in query)'
      return
    end
    if @imdb.rate(entry.id, params[:rating])
      update_ratings(nick, [{:nick => nick, :imdb_id => entry.id, :rating => params[:rating].to_i}])
      announce
    else
      reply m, '[red]unknown error occured :('
    end
  end

  def user_list(m, params)
    if @users.length > 0
      reply m, 'known users: ' + @users.map { |nick, user|
        '[b]%s[/c] (%s)' % [nohl(nick), user[:user_id]]
      }.join(' | ')
    else
      reply m, '[red]no users found!'
    end
  end

  def user_add(m, params)
    user_id = params[:user_id]
    if user_id and user_id.match /^ur\d+$/
      reply m, '[red]error[/c] - you need a valid user-id, like ur1234567'
    end
    nick = m.source.to_s
    if @users.has_key? nick
      @users[:user_id] = user_id
      m.reply '[b]success[/c] - updated your user, set user id to %s' % [user_id]
    else
      @users = {:user_id => user_id}
      m.reply '[b]success[/c] - created a user for you, and set your user id to %s' % [user_id]
    end
  end

  def user_login(m, params)
    if m.channel
      reply m, '[red]command must not be given in public[/c]'
      return
    end
    nick = m.source.to_s
    username = params[:username]
    password = params[:password].join(' ')
    # test first:
    cookie = @imdb.login(username, password)
    if not cookie
      reply m, '[red]error[/c] - unable to login'
    else
      user_id = @imdb.get_user_id
      if @users.has_key? nick
        @users[nick][:user_id] = user_id
        @users[nick][:username] = username
        @users[nick][:password] = password
        @users[nick][:cookie] = cookie
        m.reply 'set your imdb id to %s' % [user_id]
        reply m, '[b]success[/c] - updated your user, set user/pw, set user id to %s' % [user_id]
      else
        @users[nick] = {:user_id => user_id, :username => username, :password => password, :cookie => cookie}
        reply m, '[b]success[/c] - created a user for you, set user/pw, set user id to %s' % [user_id]
      end
    end
  end

  def login_as(nick)
    if @users.has_key? nick
      user = @users[nick]
      if user.has_key? :cookie
        @imdb.set_cookies(user[:cookie])
        return true if @imdb.get_user_id
      end
      cookie = @imdb.login(user[:username], user[:password])
      user[:cookie] = cookie if cookie
      return true if cookie and @imdb.get_user_id
    end
  end

  def user_remove(m, params)
    nick = m.source.to_s
    if @users.has_key? nick
      @users.remove nick
      reply m, '[b]success[/c] - removed your user data'
    else
      reply m, '[red]error[/c] - user not found'
    end
  end

  def manual_add(m, param)
    nick = param[:nick]
    user_id = param[:user_id]
    if @users.has_key? nick
      @users[nick][:user_id] = user_id
    else
      @users[nick] = {:user_id => user_id}
    end
    m.okay
  end

  def manual_announce(m, param)
    announce
  end

  def manual_announce_clear(m, param)
    @events.poll('rating')
    @events.poll('watchlist')
    m.okay
  end

  def manual_clear(m, param)
    reply m, '[b][green]removes cached ratings/watchlist'
    @ratings = {}
    @watchlist = {}
  end

  def manual_tick(m, param)
    if param.has_key? :export and param[:export] == 'export'
      @ticks = EXPORT_TICK-1 # hack, export is done every 25th time
    end

    reply m, '[b][green]do a manual tick...'
    begin
      $imdbng_profiler = MethodProfiler.observe(self.class) unless $imdbng_profiler
      debug 'start manual tick'
      start = Time.new
      tick
      duration = Time.new - start
      reply m, 'Time: %d seconds to tick (in %s mode!)' % [duration, @stats[:feed] ? 'feed' : 'export']
      reply m, 'Profiler: '+$imdbng_profiler.report.sort_by(:total_time).to_a.map { |row|
        '[b]%s[/c] (%0.2fs, %d calls)' % [row[:method], row[:total_time], row[:total_calls]]
      }.join(' | ') unless $imdbng_profiler
      reply m, 'Count: [b][royal_blue]ratings (%d/%d), watchlist (%d/%d) | (new entries/total)' % [@stats[:new_rating], @stats[:rating], @stats[:new_watchlist], @stats[:watchlist]]
    rescue
      error $!.to_s
      error $@.join "\n"
      reply m, '[b][red]error occured: ' + $!.to_s
    end
  end

  ###################################################################
  
  def message(m, dummy=nil)
    message = m.message.strip
    nick = m.source.to_s

    if message.match %r{(@)?(tt\d+) \((\d+)(?:\/10)?\)}
      imdb_id = $2
      rating = $3
      entry = @imdb.create(imdb_id)
      if not entry or entry.class >= IMDb::Title
        #reply m, '[red]error movie not found'
        return
      end
      if not login_as(nick)
        reply m, '[red]unable to rate a movie[/c], you need to login first, [b]imdb login <username> <password>[/c] (in query)'
        return
      end
      if @imdb.rate(entry.id, rating)
        update_ratings(nick, [{:nick => nick, :imdb_id => entry.id, :rating => rating.to_i}])
        announce
      else
        reply m, '[red]unknown error occured :('
      end
    elsif message.match %r{(@)?(tt\d+)}
      brief = $1
      imdb_id = $2
      entry = @imdb.create(imdb_id)
      if not entry or entry.class >= IMDb::Title
        #reply m, '[red]error movie not found'
        return
      end
      if brief and not brief.empty?
        reply m, format_entry(entry, :overview)
      else
        reply m, format_entry(entry, :overview, :plot)
      end
    end

    # tt<ID> ---somewhere in a message will display full infomration
    # @tt<ID>   --- somwhere in a message shows short one-line information about a something
    # tt<id> (<NUM>[/10]) -- rates the movie/thing with <NUM> will respond with a short announcemnt
    # +tt<id> -- adds thing to the users watchlist will respond with a short announcemnt
  end

  ###################################################################

  # does the announcement in channel(s)
  # announce, ratings, watchlist etc.
  def announce
    messages = get_announcements

    @bot.config['imdbng.announce'].each do |channel|
      messages.each do |line|
        @bot.say(channel, color_markup(line))
      end
    end
  end

  def get_announcements
    # poll from event manager:
    rating = @events.poll('rating')
    watchlist = @events.poll('watchlist')

    # sort by nick:
    # sorted = sort_me.sort_by { |k| k["value"] }
    rating = rating.sort_by { |k| k[:nick] }
    watchlist = watchlist.sort_by { |k| k[:nick] }

    lines = []
    lines += format_announcements(rating, '%s rated %s: ') do |entry, imdb| 
      imdb_id = imdb.id
      s = []
      @users.keys.each do |nick|
        next if nick == entry[:nick]
        user_rating = get_user_from_list(@ratings, nick, imdb_id)
        s << '[b]%s[/c] (%d)' % [nick, user_rating[:rating]] if user_rating
      end
      if s.length > 0
        ' | ' + s.join(', ')
      else
        ''
      end
    end
    lines += format_announcements(watchlist, '%s added %s to watchlist. ') do |entry, imdb| 
      imdb_id = imdb.id
      s = []
      @users.keys.each do |nick|
        next if nick == entry[:nick]
        user_watchlist = get_user_from_list(@watchlist, nick, imdb_id)
        s << '[b]%s[/c]' % [nick] if user_watchlist
      end
      if s.length > 0
        ' | ' + s.join(', ')
      else
        ''
      end
    end

    lines
  end

  def format_announcements(entries, format)
    lines = []
    max = entries.length == 4 ? 4 : 3
    entries[0...max].each do |entry|
      nick = entry[:nick]
      imdb_id = entry[:imdb_id]
      # load imdb object:
      entry[:obj][:cache] = imdb = @imdb.create(imdb_id)

      line = format % ['[b]'+nohl(nick)+'[/c]', format_entry(imdb, :short_title).first]
      line += '[b]%d[/c]/10. ' % entry[:rating] if entry.has_key? :rating
      line += '(%s) ' % imdb.url
      line += '[*[b]%s[/c]/10, %s voters]' % [imdb.rating, imdb.votes] if imdb.respond_to? :rating
      line += yield(entry, imdb) if block_given?

      lines << line
    end
    if entries.length > max
      lines << '[b][teal]%d left/omitted' % [entries.length - max]
    end

    lines
  end

  ###################################################################

  # private

  def find_entry(m, query, opts={})
    if @imdb.id? query
      @imdb.create(query) 
    else
      results = @imdb.search(query, opts)
      if results.empty?
        reply m, 'the search for *%s* returned nothing :/' % query
        nil # return/halt in the caller
      else
        @imdb.create(results.first[:id], opts) 
      end
    end
  end

  def format_entry(entry, *methods)
    formatter = IMDb::Formatter.new(:color_markup => true)
    methods.map { |method| formatter.send(method, entry) }
  end

  def color_markup(msg)
    def repl(msg, key, repl)
      msg.gsub(('[%s]' % key), repl)
    end
    colors = ColorCode.keys.map(&:to_s)
    msg = repl(msg, '/c', NormalText)
    msg = repl(msg, 'bold', Bold)
    msg = repl(msg, 'b', Bold)
    colors.each do |color|
      msg = repl(msg, color, Color.to_s + ('%02d' % ColorCode[color.to_sym]))
    end
    return msg
  end

  def reply(m, message) 
    if message.instance_of? Array
      message = message.compact
      message = message.join("\n")
    end
    message.gsub!(%r{}, "\\1")
    m.reply color_markup( message )
  end

  def nohl(s)
    # prevents highlights trough injecting ZERO-WIDTH-WHITESPACE
    s[0] + "\u200B" + s[1..-1]
  end

  def ctest(m, params)
    if params[:test].length <= 0
      ret = []
      ColorCode.keys.map(&:to_s).each do |col|
        ret << '[%s]%s[/c]' % [col, col]
      end
      reply(m, ret.join(', '))
      return
    end
    reply(m, params[:test].join(' '))
  end
end

plugin = ImdbNgPlugin.new

plugin.map 'imdb rate *query :rating', :action => :rate, :requirements => {:rating => /^\d+$/}, :threaded => true

plugin.map 'imdb users', :action => :user_list
plugin.map 'imdb user [list]', :action => :user_list
plugin.map 'imdb user add [:user_id]', :action => :user_add, :threaded => true
plugin.map 'imdb user login [:username] [*password]', :action => :user_login, :threaded => true
plugin.map 'imdb user remove', :action => :user_remove

plugin.map 'imdb [search] *query', :action => :search, :threaded => true
plugin.map 'imdb [tv] *query', :action => :search_tv, :threaded => true

# clears the cache of ratings / watchlist entries
plugin.map 'imdb-clear', :action => :manual_clear
# does a manual tick (use imdb-tick export to force an export tick)
plugin.map 'imdb-tick [:export]', :action => :manual_tick, :threaded => true
# announce left nofied messages publically.
plugin.map 'imdb-announce', :action => :manual_announce, :threaded => true
# clear announcements
plugin.map 'imdb-clear-announce', :action => :manual_announce_clear
# manually add a user (add id for a user not present/etc.)
plugin.map 'imdb-add [:nick] [:user_id]', :action => :manual_add

plugin.map 'ctest [*test]', :action => :ctest

