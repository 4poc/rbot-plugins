# vim: tabstop=4 expandtab shiftwidth=2 softtabstop=2
# Scraping IMDb API Library for Ruby
# Copyright (C) 2013-2014  Matthias Hecker <http://apoc.cc/>
#
#  This program is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program.  If not, see <http://www.gnu.org/licenses/>.
#  
##
# Developed for and tested with ruby >= 1.9.3 and >= 2.0.0
# Latest version at: https://github.com/4poc/rbot-plugins/tree/master/imdb2api
# Requires Mechanize.
#

require 'mechanize'

require 'date'
require 'csv'
require 'net/http'

require 'date'

if not defined? debug
  def debug(msg)
    if msg.index("\n")
      msg = msg.split("\n")
    else
      msg = [ msg ]
    end
    msg.each { |m| puts '[%s] - %s' % [Time.now, m] }
  end
  def error(msg)
    debug(msg)
  end
end

module ::IMDb
  EXPIRE_DEFAULT = 86400 # one day
  EXPIRE_LIST = 300 # 5min
  BASE_URL = 'http://www.imdb.com'
  RE_ID = %r{((tt|nm|ch)\d+)}

  class Cache
    def get(key)
      raise 'unimplemented!'
    end

    def put(key, obj, expire=EXPIRE_DEFAULT)
      raise 'unimplemented!'
    end

    def new_entry(obj, expire)
      {
        :expires => Time.now + expire,
        :obj => obj
      }
    end

    def expired? entry
      entry[:expires] <= Time.now
    end
  end

  # very simple file cache implementation, just for testing (write your own!)
  class FileCache < Cache
    def initialize
      @filename = './imdb2api.cache'
      @cache = {}
      if not File.exists? @filename
        save_cache
      else
        load_cache
      end
    end

    def get(key)
      if @cache.has_key? key and not expired? @cache[key]
        #puts
        #debug '--- cache hit ---'
      else
       # puts
        #debug '--- cache miss ---'
      end
      #puts
      @cache[key][:obj] if @cache.has_key? key and not expired? @cache[key]
    end

    def put(key, obj, expire=EXPIRE_DEFAULT)
      #debug 'filecache, put in cache: '+key.inspect
      @cache[key] = new_entry(obj, expire)

      save_cache
    end

    private

    def load_cache
      begin
        @cache = Marshal.load(File.read(@filename))
      rescue
        error 'load cache error: '+$!.to_s
        error $@.join("\n")
        @cache = {}
      end
    end

    def save_cache
      File.open(@filename, 'w') { |f| f.write(Marshal.dump(@cache)) }
    end
  end

  class MemoryCache < Cache
    attr_accessor :cache

    def initialize(cache)
      @cache = cache
    end

    def get(key)
      if @cache.has_key? key and not expired? @cache[key]
      else
      end
      #puts
      @cache[key][:obj] if @cache.has_key? key and not expired? @cache[key]
    end

    def put(key, obj, expire=EXPIRE_DEFAULT)
      #debug 'memorycache, put with key: '+key.inspect
      @cache[key] = new_entry(obj, expire)
    end
  end

  class Api
    attr_accessor :use_cache
    attr_reader :agent, :cache

    def initialize(opts={})
      @cache = opts[:cache] || FileCache.new
      @agent = Mechanize.new
      @agent.max_history = 1
      @agent.user_agent_alias = 'Linux Firefox'
      @use_cache = opts.has_key?(:use_cache) ? opts[:use_cache] : true
    end

    ##
    # Search IMDb for movies, etc.
    #
    # query: search words
    # opts:  exact (false) query must match exactly
    #        limit (nil) limit search result number
    ##
    def search(query, opts={})
      clear_cookies
      find_url = BASE_URL + '/find?q=%s' % CGI.escape(query)
      results = @cache.get(find_url)
      if not results or not @use_cache
        page = @agent.get(find_url)
        results = page.search('.findResult .result_text a').map do |result|
          url = result.attributes['href'].value.gsub(/\/\?.*?$/, '')
          title = result.text
          if url.match RE_ID
            { :id => $1,
              :type => $2,
              :url => url,
              :title => title }
          end
        end
        @cache.put(find_url, results)
      end

      # should never happen, but remove broken results
      results.reject! do |result|
        result == nil
      end

      if opts[:limit]
        results = results.first opts[:limit]
      end
      if opts[:exact]
        results.reject! do |result|
          query.upcase != result[:title].upcase
        end
      end
      if opts[:type]
        results.reject! do |result|
          result[:type] != opts[:type]
        end
      end

      results
    end

    def create(id, opts={})
      clear_cookies
      case id.match(RE_ID)[2]
      when 'tt'
        if @use_cache
          entry = @cache.get(id)
          if entry
            #debug '--- (use object cache for id=%s)' % id
            entry.load_series!(self) if opts[:load_series] and entry.instance_of? Series and not entry.series_loaded?
            return entry
          end
        end
        # discover if its a title, series or episode:
        type = Title.discover(self, id)
        entry = type.new id
      when 'nm'
        entry = Name.new id
      when 'ch'
        entry = Character.new id
      else
        raise 'search result item unimplemented: ' + id.match(RE_ID)[2]
      end

      begin
        entry.load!(self)
        entry.load_series!(self) if opts[:load_series] and entry.instance_of? Series
      rescue
        debug 'ERROR parsing entry IMDb ' + entry.url
        debug $!.to_s
        debug $@.join("\n")
        return nil
      end
      entry.cache!(self)
      entry
    end

    def id?(id)
      RE_ID.match id
    end

    def get_cached_url(url)
      body = @cache.get(url)
      if not body or not @use_cache
        page = @agent.get(url)
        @cache.put(url, page.body)
        page.parser
      else
        Nokogiri::HTML(body)
      end
    end

    def clear_cookies
      @agent.cookie_jar = Mechanize::CookieJar.new
    end

    def set_cookies(cookies)
      @agent.cookie_jar = cookies
    end

    # login, return cookie
    def login(username, password)
      url = 'https://secure.imdb.com/oauth/login?show_imdb_panel=1'
      begin
        clear_cookies
        page = @agent.get(url)
        form = page.forms.first
        form.login = username
        form.password = password
        page = form.submit
        if page.uri.to_s.match /closer/
          @agent.cookie_jar
        else
          nil
        end
      rescue
        error $!.to_s
        error $@.join "\n"
        nil
      end
    end

    def get_user_id
      page = @agent.get 'http://www.imdb.com/list/ratings'
      # should redirect us, now with ur<id> in the url:
      if page.uri.to_s.match /(ur\d+)/
        return $1
      end
    end

    def feed(user_id, type='ratings')
      url = 'http://rss.imdb.com/user/%s/%s' % [user_id, type]
      ratings = []

      begin
        feed = @agent.get url
      rescue # Net::HTTPNotFound
        return nil # user set this to private (probaply)
      end
      feed = Nokogiri::XML(feed.body)
      feed.xpath('//item').each do |item|
        obj = {}

        link = item.xpath('./link').inner_text
        if link.match /(tt\d+)/
          obj[:imdb_id] = $1
        end

        rate = item.xpath('./description').inner_text
        if rate.match /rated this (\d+)\./
          obj[:rating] = $1.to_i
        end
 
        ratings << obj
      end

      ratings
    end

    # csv export of any user requires login as anyone user
    def export(user_id, type='ratings')
      url = BASE_URL + '/list/export?list_id=%s&author_id=%s' % [type, user_id]
      csv = @cache.get(url)
      if not csv or not @use_cache
        begin
          page = @agent.get url
        rescue # Net::HTTPNotFound
          return nil # user set this to private (probaply)
        end
        csv = page.body
        @cache.put(url, csv, EXPIRE_LIST)
      end
      list = CSV.parse(csv)
      header = list.shift
      fields = {
        :imdb_id => /const/,
        :rating => /.* rated/,
        :created => /created/,
        :updated => /modified/
      }
      fields.each_key do |key|
        header.each_index do |i|
          heading = header[i]
          if fields[key].instance_of?(Regexp) and heading.match(fields[key])
            fields[key] = i
          end
        end
      end
      list.map do |entry|
        obj = {}
        fields.each_pair do |key, i|
          obj[key] = entry[i].match(/^\d+$/) ? entry[i].to_i : entry[i]
          if key == :created or key == :updated
            obj[key] = DateTime.parse(obj[key]) if not obj[key].empty?
          end
        end
        obj
      end
    end

    def rate(imdb_id, rate)
      url = '%s/title/%s' % [BASE_URL, imdb_id]
      page = @agent.get url+'/reference'
      link = page.search '//a[contains(@href, "vote?v=%d;")]/@href' % [rate]
      if not link or link.empty?
        return false
      end
      agent.get url + '/' + link.first.value
      return true
    end

    def check_cache(imdb_id)
      # check if urls of this item can be found in the cache:
      base = false
      series = false
      cached_entry = @cache.get(imdb_id)
      if cached_entry
        base = true
        if cached_entry.kind_of? Series
          if cached_entry.series_loaded?
            series = true
          end
        end
      end
      {:base => base, :series => series}
    end
  end

  class Formatter
    attr_accessor :color_markup, :brief, :tv_schedule

    def initialize(opts={})
      @color_markup = opts[:color_markup]
    end

    def overview(entry)
      if entry.kind_of? Title # also for Episodes and Series
        overview_title entry
      elsif entry.kind_of? Name
        overview_name entry
      elsif entry.kind_of? Character
        overview_character entry
      end
    end

    def short_title(entry)
      format([
          # title, in quotes if tv series/ episode
          title(entry),

          # season/episode and series
          format([
            season_and_episode(entry),
            'of',
            series(entry)
          ], :ignore => true),

          # countries and release year
          country_and_year(entry),
      ], :seperator => [' '])
    end

    def overview_title(entry)
      format([
        [
          # title, in quotes if tv series/ episode
          title(entry),

          # season/episode and series
          format([
            season_and_episode(entry),
            'of',
            series(entry)
          ], :ignore => true),

          # countries and release year
          country_and_year(entry),

          # show (in development) if its in development
          in_development(entry)

        ],

        # ratings and number of votes
        ratings_and_votes(entry),

        # genre and creator
        format([
          genre(entry),
          creator(entry)
        ], :ignore => true),

        entry.url

      ], :seperator => [' | ', ' '])
    end

    def overview_name(entry)
      format([
        entry.name,
        entry.url
      ], :seperator => ' | ')
    end

    def overview_character(entry)
      format([
        entry.name,
        entry.url
      ], :seperator => ' | ')
    end

    def schedule(entry)
      return if not entry.instance_of? Series
      raise 'series data not loaded?' if not entry.series_loaded?

      format([
        episode_count(entry),
        season_count(entry),

        format([
          'last episode', schedule_episode(entry.get_last_episode),
        ], :ignore => true),

        format([
          'next episode', schedule_episode(entry.get_next_episode),
        ], :ignore => true),

        future_episode_count(entry)

      ], :seperator => ' | ')
    end

    def schedule_episode(episode)
      return if not episode
      format([
        episode_airdate(episode, true),
        format([episode_airdate(episode)], :ignore=>true, :format=>'[%s]'),
        season_and_episode(episode),
        title(episode)
      ])
    end

    def episode_airdate(entry, hr=false)
      return if not entry.airdate
      if hr
        hr_date entry.airdate
      else
        entry.airdate.to_time.strftime('%d.%m.%Y')
      end
    end

    def episode_count(entry)
      '%d episodes' % entry.get_episode_count
    end

    def future_episode_count(entry)
      count = entry.get_future_episode_count
      '%d episodes left/announced' % count if count and count > 0
    end

    def season_count(entry)
      '%d seasons' % entry.seasons
    end

    def title(entry)
      if entry.instance_of? Series or entry.instance_of? Episode
        ('"'+cl('bold')+'%s'+cl+'"') % entry.title
      else
        if entry.type != 'Feature Film'
          (cl('bold')+'%s'+cl+', %s') % [entry.title, entry.type]
        else
          cl('bold')+entry.title+cl
        end
      end
    end

    def plot(entry)
      if entry.respond_to? :plot
        entry.plot
      end
    end

    def genre(entry)
      entry.genre.join('/')
    end

    def creator(title)
      if not title.creator.empty?
        'by ' + hr_list(title.creator)
      elsif not title.director.empty?
        'by ' + hr_list(title.director)
      elsif not title.actors.empty?
        'with ' + hr_list(title.actors)
      end
    end

    def season_and_episode(entry)
      if entry.instance_of? Episode
        'S%02dE%02d' % [entry.season, entry.episode]
      end
    end

    def series(entry)
      '"%s"' % entry.series if entry.instance_of? Episode
    end

    def country_and_year(entry)
      if entry.respond_to? :airdate
        year = entry.airdate.strftime('%d.%m.%Y')
      else
        year = entry.year
      end
      format([
        entry.country,
        year
      ], :seperator => [', ', '/'],
         :format => '(%s)',
         :ignore => true)
    end

    def ratings_and_votes(entry)
      format([
        entry.rating,
        format([
          entry.votes,
          'voters'
        ], :format => '(%s)',
           :ignore => true)
      ], :ignore => true)
    end

    def in_development(entry)
      '(in development)' if entry.in_development
    end

    # complex formatting helper, implementation a little clumsy :/
    def format(arr, opts={})
      # if seperator is an array, it is using different seperators for inner arrays
      seperator = opts[:seperator] || ' '
      #indicates if it should return nil if one of arr's elements is nil
      ignore = opts.has_key?(:ignore) ? opts[:ignore] : false
      format = opts[:format] || '%s'

      # determine if there empty elements in the array
      def has_empty?(a)
        if a.instance_of? Array
          ret = false
          a.each { |x| ret = true if has_empty?(x) }
          ret
        else
          not a or a.empty?
        end
      end
      includes_empty = has_empty? arr

      # arrays to string using the seperators
      seperator = [seperator] if not seperator.kind_of? Array
      def visit(ar, lvl, seperator)
        sep = seperator[lvl]
        sep = seperator.first if not sep
        s = ar.map do |element|
          if element.kind_of? Array
            visit(element, lvl + 1, seperator)
          else
            element
          end
        end
        s.reject! { |x| not x or x.empty? } # remove empty/nil elements
        s.join(sep) 
      end
      str = visit(arr, 0, seperator)

      if includes_empty and ignore
        nil
      else
        format % [str]
      end
    end

    private

    def cl(color=nil)
      if @color_markup
        if not color
          '[/c]'
        else
          '[%s]' % color
        end
      else
        ''
      end
    end

    def hr_list(list)
      list = list.dup
      if list.length > 1
        last = list.pop
        list.join(', ') + ' and ' + last
      else
        list.first
      end
    end

    DAY = 86400
    WEEK = 604800
    MONTH = 2628000
    YEAR = 31540000

    def hr_date(date)
      delta = (Date.today.to_time - date.to_time).to_i

      postfix = prefix = ''
      if delta > 0
        postfix = ' ago'
      elsif delta < 0
        prefix = 'in '
      end

      delta = delta.abs

      if delta < DAY
        str = 'today'
      elsif delta < WEEK
        days = delta / DAY
        if days == 1
          str = 'one day'
        else
          str = '%d days' % days
        end
      elsif delta < MONTH
        weeks = delta / WEEK
        if weeks == 1
          str = 'one week'
        else
          str = '%d weeks' % weeks
        end
      elsif delta < YEAR
        months = delta / MONTH
        if months == 1
          str = 'one month'
        else
          str = '%d months' % months
        end
      else
        years = delta / YEAR
        if years == 1
          str = 'one year'
        else
          str = '%d years' % years
        end
      end
      prefix + str + postfix
    end
  end

  private

  ##
  # Base for imdb entries of different types.
  #
  # Like titles (tt), names (nm) or characters (ch)
  ##
  class Entry
    attr_accessor :page # just to remove it later
    attr_reader :id, :description

    def initialize(id)
      @id = id
    end

    def url
      BASE_URL
    end

    def load! api
      @page = api.agent.get url

      # description (og:description) includes producers, actors, plot
      @description = @page.search('meta[name="description"]/@content').first.value
    end

    def cache! api
      if api.use_cache
        @page = nil
        api.cache.put(@id, self)
      end
    end

    def to_hash
      hash = {}
      instance_variables.each do |v| 
        begin
          hash[v[1..-1]] = public_send("#{v[1..-1]}")
        rescue
        end
      end
      return hash
    end

    def to_s
      '[%s]' % @id
    end

    private

    def parse(pattern, desc)
      begin
        @page.search(pattern).map(&:content).map(&:strip)
      rescue
        debug 'IMDb ERROR parsing %s: %s' % [desc, $!.to_s]
      end
    end
  end

  ##
  # Movie, TV Show or similar entry in IMDb.
  ##
  class Title < Entry
    attr_reader :type, :title, :english_title, :year, :country, :director, :rating, :votes, :genre, :plot, :creator, :actors, :release_date, :language, :budget, :runtime, :in_development

    RE_IN_DEVELOPMENT = %r{this project is categorized as <i>in development,</i>}
    TYPE = '//*[contains(@class, "infobar")]/text()'
    YEAR = 'h1.header .nobr'
    #COUNTRY = '//*[contains(@class, "txt-block")]/*[contains(text(), "Country")]/../a/text()'
    COUNTRY = '//*[contains(@class, "txt-block")]/h4[contains(text(), "Country")]/../a/text()'
    RATING = '//*[contains(@class, "title-overview")]//*[contains(@itemprop, "ratingValue") and not(@class)]/text()'
    VOTES = '//*[contains(@class, "title-overview")]//*[contains(@itemprop, "ratingCount") and not(@class)]/text()'
    GENRE = '//*[@itemprop="genre"]/*[contains(text(), "Genres")]/../a/text()'
    PLOT = 'p[itemprop="description"]'
    DIRECTOR = '.txt-block[itemprop="director"] a .itemprop[itemprop="name"]'
    CREATOR = '.txt-block[itemprop="creator"] a .itemprop[itemprop="name"]'
    ACTORS = '.txt-block[itemprop="actors"] a .itemprop[itemprop="name"]'
    LANGUAGE = '//*[contains(@class, "txt-block")]/*[contains(text(), "Language")]/../a/text()'
    RELEASE_DATE ='//*[contains(@class, "txt-block")]/*[contains(text(), "Release Date")]/following-sibling::text()[1]' ''
    BUDGET = '//*[contains(@class, "txt-block")]/*[contains(text(), "Budget")]/following-sibling::text()[1]'
    RUNTIME = '//*[contains(@class, "txt-block")]/*[contains(text(), "Runtime")]/../time/text()'

    def url
      super + '/title/' + @id
    end

    def to_s
      if @country and @year
        super + (' %s (%s %s)' % [@type, @country.join('/'), @year])
      else
        super + (' %s' % [@type])
      end
    end

    def load! api
      super api

      # parse type
      type = @page.search(TYPE).first
      if type
        #debug type.inspect
        matches = type.content.scan(/\w+/)
        if not matches.empty?
          @type = matches.join(' ')
          @type = @type.split.join(' ')
        end
      end
      @type = 'Feature Film' if not @type or @type.empty?

      # Title and original title:
      @title = @page.search('.header .itemprop[itemprop="name"]').first.content.strip
      match = @page.search('.header .title-extra[itemprop="name"]')
      original_title = match.first.content.strip if not match.empty?

      # title extra should contain the (original title) otherwise warn about it
      if original_title and original_title.index('(original title)')
        original_title.gsub!(/\(original title\)/, '')
        original_title.gsub!(/^\"(.*)\"$/, '\\1')
        original_title.strip!
      elsif original_title
        debug 'warn: unrecognized title-extra for ' + url
      end

      # switch original_title <-> title
      if original_title
        @english_title = @title
        @title = original_title
      end

      @in_development = (not (@page.root.inner_html.match(RE_IN_DEVELOPMENT)).nil?)

      # parse plot without 'see more'
      plot_node = @page.search(PLOT)
      if plot_node and plot_node.length > 0
        plot_node.first.children.each do |child|
          child.remove if child.name == 'a'
        end
        @plot = plot_node.children.map(&:content).map(&:strip).first.strip
      else
        @plot = nil
      end

      @year = parse(YEAR, 'release year').first
      @budget = parse(BUDGET, 'budget').first
      @release_date = parse(RELEASE_DATE, 'release date').first
      @rating = parse(RATING, 'rating').first
      @votes = parse(VOTES, 'votes').first
      @country = parse(COUNTRY, 'countries')
      @genre = parse(GENRE, 'genre')
      @director = parse(DIRECTOR, 'list of directors').uniq
      @creator = parse(CREATOR, 'list of creators/writers').uniq
      @actors = parse(ACTORS, 'list of actors').uniq
      @language = parse(LANGUAGE, 'languages')
      @runtime = parse(RUNTIME, 'runtime/duration')

      if @year
        @year.gsub!(/[\(|\)]/, '')
        @year.gsub!(/\u2013/, '-')
        @year.strip!
      end
    end

    # discovers what kind of title it is: title, series or episode
    # this needs to be done before the entry instance is initialized,
    # it caches the page (reparsed through)
    def self.discover(api, id)
      if api.use_cache
        entry = api.cache.get(id)
        return entry.class if entry
      end
      page = api.agent.get(BASE_URL + '/title/' + id)
      type = page.search(TYPE).first
      if type
        matches = type.content.scan(/\w+/)
        if not matches.empty?
          type = matches.join(' ').split.join(' ')

          if type == 'TV Series'
            return Series
          elsif type == 'TV Episode'
            return Episode
          end
        end
      end

      Title
    end
  end

  # includes episode information of the tv show
  class Series < Title

    attr_reader :seasons, :episodes

    SEASONS = '//*[contains(@class, "txt-block")]/*[contains(text(), "Season")]/../span/a'

    def load! api
      super api
      raise 'Series instance is not a tv series!' if @type != 'TV Series'
    end

    # loads additional information about the tv series, including episode
    # information. Requests one url per season.
    def load_series! api
      @seasons = 1 # determined later
      @episodes = []
      current_season = 1
      begin
        season_url = url + '/episodes?season=%d' % current_season
        load_season!(api, season_url, current_season)
        current_season+=1
      end until current_season > @seasons

      # number all episodes
      num = 1
      @seasons.times do |season|
        sorted_episodes = get_season(season+1).sort_by {|epi| epi.episode}
        sorted_episodes.each do |epi|
          epi.number = num
          num += 1
          #debug '%s S%02dE%02d [%d] -- %s' % [title, epi.season, epi.episode, epi.number, epi.airdate]
        end
      end

      # remove pages:
      @episodes.each do |episode|
        episode.page = nil
      end

      @series_loaded = true
    end

    def series_loaded?
      @series_loaded
    end

    def get_episode(season, episode)
      @episodes.select do |e|
        e.season == season and e.episode == episode
      end.first
    end

    def get_season(season)
      @episodes.select do |e|
        e.season == season
      end
    end

    def get_last_episode
      get_sorted_episodes.reverse.find { |episode| episode.airdate and episode.airdate.to_time <= Date.today.to_time }
    end

    def get_next_episode
      get_sorted_episodes.find { |episode| episode.airdate and episode.airdate.to_time >= Date.today.to_time }
    end

    def get_episode_count
      get_sorted_episodes.last.number
    end

    def get_future_episode_count
      return 0 if not get_next_episode
      get_episode_count - get_next_episode.number + 1
    end

    def get_sorted_episodes # sort by airdate and episode number
      if not @sorted_episodes
        #@sorted_episodes = @episodes.sort_by do |episode|
        #  [episode.airdate, episode.number]
        #end
        # somewhat klumsy approach I feel:
        @sorted_episodes = @episodes.sort do |a, b|
          if not a.airdate or not b.airdate
            comp = 0
          else
            comp = (a.airdate.to_time.to_i <=> b.airdate.to_time.to_i)
          end
          if not a.number or not b.number
            comp
          else
            comp.zero? ? (a.number <=> b.number) : comp
          end
        end
      end
      @sorted_episodes
    end

    private

    def load_season!(api, url, num)
      @page = api.agent.get(url)

      #
      # SIDEFFECT! This updates the @seasons attribute with the total number
      #  of seasons. That effects the loop in load! Details:
      #     The main series page does not include links to all seasons, thats
      #     why we get the first season details (with all the episodes of season 1) first
      #     that page includes a list of all seasons as a dropdown menu, we need
      #     that information in the loop of load_series.
      @page.search('select#bySeason option/@value').each do |option|
        if @seasons < option.content.strip.to_i
          @seasons = option.content.strip.to_i
        end
      end

      @page.search('.info[itemprop="episodes"]').each do |episode|
        episode_num = episode.search('meta[itemprop="episodeNumber"]/@content').first.value.to_i
        airdate = episode.search('.airdate').first.content.strip
        if airdate.match /^\d+ \w+\.? \d{4}$/
          airdate = Date.strptime(airdate.gsub(/(\w+)\./, '\\1'), '%e %b %Y')
        elsif airdate.match /^\w+\.? \d+, \d{4}$/
          airdate = Date.strptime(airdate.gsub(/^(\w+)\./, '\\1'), '%b %e, %Y')
        #elsif airdate.match /(\w+). (\d{4})/
        #  airdate = Date.strptime('01 %s %d' % [$1, $2], '%d %b %Y')
        #elsif airdate.match /(\d{4})/
        #  airdate = Date.strptime('01 01 %d' % $1, '%d %m %Y')
        else
          airdate = nil
        end
        title = episode.search('a[itemprop="name"]').first
        url = title.attributes['href'].value
        title = title.content.strip
        plot = episode.search('.item_description[itemprop="description"]').first.content.strip

        raise 'episode url not found' if not url.match(RE_ID)

        entry = Episode.new $1
        entry.season = num
        entry.episode = episode_num
        entry.title = title
        entry.plot = plot
        entry.airdate = airdate

        @episodes << entry
      end
    end
  end

  class Episode < Title
    attr_accessor :season, :episode, :number, :title, :plot, :airdate, :series, :series_id

    SERIES = '.tv_header a'
    NUMBERS = '.tv_header .nobr'

    def load! api
      super api

      series = @page.search(SERIES).first
      @series = series.content.to_s.strip
      url = series.attributes['href'].value
      url.match RE_ID
      @series_id = $1

      numbers = parse(NUMBERS, 'episode number/season number').first
      if numbers.match /Season (\d+), Episode (\d+)/
        @season = $1.to_i
        @episode = $2.to_i
      end

      if @year.match /^\d+ \w+\.? \d{4}$/
        @airdate = Date.strptime(@year.gsub(/(\w+)\./, '\\1'), '%e %b %Y')
        @year = @airdate.strftime('%Y')
      elsif @year.match /^\w+\.? \d+, \d{4}$/
        @airdate = Date.strptime(@year.gsub(/^(\w+)\./, '\\1'), '%b %e, %Y')
        @year = @airdate.strftime('%Y')
      end
    end
  end

  class Name < Entry
    attr_reader :name

    def url
      super + '/name/' + @id
    end

    def load! api
      super api

      # Title and original title:
      @name = parse('.header .itemprop[itemprop="name"]', 'person name').first
      @name.gsub!(/\(\w+\)/, '')
      @name.strip!
    end
  end

  class Character < Entry
    attr_reader :name, :ref_id, :ref_title

    def url
      super + '/character/' + @id
    end

    def load! api
      super api

      # Name of the character (from the page title)
      @name = parse('meta[@property="og:title"]/@content', 'character name').first
      @name.gsub!(/\(Character\)/, '')
      @name.strip!

      # The reference to the movie this character is appearing:
      movref = @page.search('#tn15main #tn15title h1 span a').first
      ref_url = movref.attributes['href'].value
      if ref_url.match RE_ID
        @ref_id = $1
      end
      @ref_title = movref.content.strip
    end
  end
end


