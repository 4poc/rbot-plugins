
require_relative 'imdb2api'

require 'test/unit'

class TestIMDb < Test::Unit::TestCase
  RE_RATINGS = %r{[\d\.]+ \([\d,]+ voters\)}

  def test_encoding
    api = IMDb::Api.new
    entry = api.create('tt0472106')
    assert_equal('U+00E4', 'U+%04X' % entry.title[1].ord)
  end

  def test_formatter_schedule
    f = IMDb::Formatter.new
    api = IMDb::Api.new
    entry = api.create('tt0098904', :load_series => true)
    assert_match(%r{172 episodes | 9 seasons | last episode \d+ years ago [14.05.1998] S09E22 "The Finale"}, f.schedule(entry))

    entry = api.create('tt0068098', :load_series => true)
    assert_match(%r{251 episodes | 11 seasons | last episode \d+ years ago [28.02.1983] S11E16 "Goodbye, Farewell, and Amen"}, f.schedule(entry))
  end

  def test_formatter_overview_series
    f = IMDb::Formatter.new
    api = IMDb::Api.new
    entry = api.create('tt0098904')
    assert_match(%r{^"Seinfeld" \(USA, 1989-1998\) \| #{RE_RATINGS} \| Comedy by Larry David and Jerry Seinfeld \| http://www\.imdb\.com/title/tt0098904$}, f.overview(entry))
  end

  def test_formatter_overview_episode
    f = IMDb::Formatter.new
    api = IMDb::Api.new
    entry = api.create('tt0697782')
    assert_match(%r{^"The Soup Nazi" S07E06 of "Seinfeld" \(USA, 2 Nov\. 1995\) \| #{RE_RATINGS} \| Comedy by Larry David and Jerry Seinfeld \| http://www\.imdb\.com/title/tt0697782$}, f.overview(entry))
  end

  def test_formatter_overview_movie
    f = IMDb::Formatter.new
    api = IMDb::Api.new
    entry = api.create('tt0133093')
    assert_match(%r{^The Matrix \(USA/Australia, 1999\) \| #{RE_RATINGS} \| Action/Sci-Fi by Andy Wachowski and Lana Wachowski \| http://www\.imdb\.com/title/tt0133093$}, f.overview(entry))

    entry = api.create('tt2705546')
    assert_match(%r{^Les Aventures de Franck et Foo-Yang, TV Mini Series \(France, 1989\) \| Sci-Fi with Jean-Yves Chalangeas, Jacques Duby and Yamato Huy \| http://www\.imdb\.com/title/tt2705546$}, f.overview(entry))
  end

  def test_formatter_overview_in_development_movie
    f = IMDb::Formatter.new
    api = IMDb::Api.new
    entry = api.create('tt0499097')
    assert_match(%r{^Without Remorse \(in development\) \| http://www\.imdb\.com/title/tt0499097$}, f.overview(entry))
  end

  def test_formatter_overview_tv_movie
    f = IMDb::Formatter.new
    api = IMDb::Api.new
    entry = api.create('tt0126220')
    assert_match(%r{^A Bright Shining Lie, TV Movie \(USA, 1998\) \| #{RE_RATINGS} \| Drama/War by Neil Sheehan and Terry George \| http://www\.imdb\.com/title/tt0126220$}, f.overview(entry))
  end

  def test_formatter_overview_actor
    f = IMDb::Formatter.new
    api = IMDb::Api.new
    entry = api.create('nm0000323')
    assert_equal('Michael Caine | http://www.imdb.com/name/nm0000323', f.overview(entry))
  end

  def test_formatter_overview_character
    f = IMDb::Formatter.new
    api = IMDb::Api.new
    entry = api.create('ch0000007')
    assert_equal('James Bond | http://www.imdb.com/character/ch0000007', f.overview(entry))
  end

  def test_formatter_ratings_and_votes
    f = IMDb::Formatter.new
    api = IMDb::Api.new
    entry = api.create('tt0177789')
    assert_match(/^#{RE_RATINGS}$/, f.ratings_and_votes(entry))
    entry = api.create('tt0499097')
    assert_equal(nil, f.ratings_and_votes(entry))
  end

  def test_formatter_country_and_year
    f = IMDb::Formatter.new
    api = IMDb::Api.new
    entry = api.create('tt0133093')
    assert_match('(USA/Australia, 1999)', f.country_and_year(entry))
    entry = api.create('tt0499097')
    assert_equal(nil, f.country_and_year(entry))
  end

  def test_formatter_format
    f = IMDb::Formatter.new

    # simple 1-dimensional:
    assert_equal('a b c', f.format(%w{a b c}))
    assert_equal('a, b, c', f.format(%w{a b c}, :seperator => ', '))
    assert_equal(nil, f.format(['a', nil, 'c'], :ignore => true))
    assert_equal('a c', f.format(['a', nil, 'c']))
    assert_equal('a c', f.format(['a', '', 'c']))
    assert_equal('(a b c)', f.format(%w{a b c}, :format => '(%s)'))
    assert_equal(nil, f.format(['a', nil, 'c'], :ignore => true, :format => '(%s)'))

    # multi dimensional:
    assert_equal('a b c d', f.format(['a', ['b', 'c'], 'd']))
    assert_equal('a b c d', f.format(['a', ['b', nil, 'c'], 'd']))
    assert_equal('a b c d', f.format(['a', ['b', '', 'c'], 'd']))
    assert_equal(nil, f.format(['a', ['b', nil, 'c'], 'd'], :ignore => true))
    assert_equal(nil, f.format(['a', ['b', '', 'c'], 'd'], :ignore => true))
    assert_equal('a, b, c, d', f.format(['a', ['b', 'c'], 'd'], :seperator => ', '))
    assert_equal('a, b/c, d', f.format(['a', ['b', 'c'], 'd'], :seperator => [', ', '/']))
  end

  def test_discovery
    api = IMDb::Api.new
    entry = api.create('tt0177789')
    assert_equal(IMDb::Title, entry.class)
    entry = api.create('tt0098904')
    assert_equal(IMDb::Series, entry.class)
    entry = api.create('tt0697782')
    assert_equal(IMDb::Episode, entry.class)
  end

  def test_episode
    api = IMDb::Api.new
    entry = api.create('tt0697782')
    assert_equal('Seinfeld', entry.series)
    assert_equal('tt0098904', entry.series_id)
    assert_equal(7, entry.season)
    assert_equal(6, entry.episode)
    assert_equal('2 Nov. 1995', entry.year)
  end

  def test_file_cache
    cache = IMDb::FileCache.new
    cache.put('foo', {:bar => 'baz'})
    assert_equal({:bar => 'baz'}, cache.get('foo'))
  end

  def test_entry_to_s
    api = IMDb::Api.new
    mov = api.create('tt0177789')
    assert_equal('[tt0177789] Feature Film (USA 1999)', mov.to_s)
  end

  def test_by_id
    api = IMDb::Api.new

    assert(api.id?('tt0133093'))

    mov = api.create('tt0133093')

    assert_instance_of(IMDb::Title, mov, 'matrix is a title object')
    assert_equal('tt0133093', mov.id)
    assert_equal('http://www.imdb.com/title/tt0133093', mov.url)
    assert_equal('The Matrix', mov.title)
    assert_equal('1999', mov.year)
    assert_equal('Directed by Andy Wachowski, Lana Wachowski.  With Keanu Reeves, Laurence Fishburne, Carrie-Anne Moss, Hugo Weaving. A computer hacker learns from mysterious rebels about the true nature of his reality and his role in the war against its controllers.', mov.description)
    assert_equal(['USA', 'Australia'], mov.country)
    assert_equal(['Andy Wachowski', 'Lana Wachowski'], mov.director)
    assert_match(/^\d+\.\d+$/, mov.rating)
    assert_match(/^\d+,\d+$/, mov.votes)
    assert_equal(['Action', 'Sci-Fi'], mov.genre)
  end

  def test_search
    api = IMDb::Api.new
    mov = api.search('The Matrix', {:exact => true, :limit => 1, :type => 'tt'})

    assert_equal(1, mov.length, 'search result should return one movie')
    assert_equal('tt0133093', mov.first[:id], 'id of the matrix expected')
    assert_equal('The Matrix', mov.first[:title])

    mov = api.create(mov.first[:id])

    assert_instance_of(IMDb::Title, mov, 'matrix is a title object')
    assert_equal('tt0133093', mov.id)
    assert_equal('http://www.imdb.com/title/tt0133093', mov.url)
    assert_equal('The Matrix', mov.title)
    assert_equal('1999', mov.year)
    assert_equal('Directed by Andy Wachowski, Lana Wachowski.  With Keanu Reeves, Laurence Fishburne, Carrie-Anne Moss, Hugo Weaving. A computer hacker learns from mysterious rebels about the true nature of his reality and his role in the war against its controllers.', mov.description)
    assert_equal(['USA', 'Australia'], mov.country)
    assert_equal(['Andy Wachowski', 'Lana Wachowski'], mov.director)
    assert_match(/^\d+\.\d+$/, mov.rating)
    assert_match(/^\d+,\d+$/, mov.votes)
    assert_equal(['Action', 'Sci-Fi'], mov.genre)
  end

  def test_english_title
    api = IMDb::Api.new
    mov = api.search('Das Leben der Anderen', {:limit => 1, :type => 'tt'})

    assert_equal(1, mov.length, 'search result should return one movie')
    assert_equal('tt0405094', mov.first[:id], 'id of the live of others expected')
    assert_equal('The Lives of Others', mov.first[:title])

    mov = api.create(mov.first[:id])

    assert_instance_of(IMDb::Title, mov, 'the lives of others is a title object')
    assert_equal('tt0405094', mov.id)

    assert_equal('Das Leben der Anderen', mov.title)
    assert_equal('The Lives of Others', mov.english_title)
  end

  def test_name
    api = IMDb::Api.new
    res = api.search('Michael Caine')

    assert(res.length >= 1, 'should return atleast one name')
    assert_equal('Michael Caine', res.first[:title])
    assert_equal('nm0000323', res.first[:id])

    name = api.create(res.first[:id])

    assert_instance_of(IMDb::Name, name, 'michael caine should be a name obj')
    assert_equal('nm0000323', name.id)
    assert_equal('Michael Caine', name.name)
  end

  def test_character
    api = IMDb::Api.new
    char = api.create('ch0000007')
    assert_instance_of(IMDb::Character, char, 'james bond is a character')
    assert_equal('James Bond', char.name)

    assert_equal('Casino Royale', char.ref_title)
    assert_equal('tt0381061', char.ref_id)
  end

  def test_parse_search_results
    api = IMDb::Api.new
    res = api.search('Ring')

    assert(res.length >= 1, 'should return atleast one title')
    res.each do |mov|
      api.create(mov[:id])
    end
  end

  def test_only_return_titles
    api = IMDb::Api.new
    res = api.search('Harry Brown', :type => 'tt')

    assert(res.length >= 1, 'should return atleast one title')
    res.each do |mov|
      assert_equal('tt', mov[:type])
    end
  end

  def test_detail_information
    api = IMDb::Api.new
    mov = api.create('tt1289406')
    assert_equal("An elderly ex-serviceman and widower looks to avenge his best friend's murder by doling out his own form of justice.", mov.plot)
    assert(mov.creator.include?('Gary Young'), 'creator must contain gary young')
    assert(mov.actors.include?('Michael Caine'), 'actors must contain michael cain')
    assert_equal('11 November 2009 (UK)', mov.release_date)
    assert(mov.language.include?('English'), 'languages must contain english')

    assert_equal('$7,300,000', mov.budget)
    assert_equal(['103 min', '97 min'], mov.runtime)
  end

  def test_types
    api = IMDb::Api.new
    assert_equal('Feature Film', api.create('tt1289406').type)
    assert_equal('TV Movie', api.create('tt2279864').type)
    assert_equal('TV Series', api.create('tt0108778').type)
  end

  def test_tv_show_episodes_without_airdate
    api = IMDb::Api.new
    results = api.search('Quick Draw')
    assert(results.length > 0)
    entry = results.first
    item = api.create(entry[:id], :load_series => true)
    puts item.get_sorted_episodes.first

  end

  def test_tv_show_episodes
    api = IMDb::Api.new
    show = api.create('tt0108778')
    show.load_series! api
    assert_equal('1994-2004', show.year)
    assert_equal(10, show.seasons)
    episode = show.get_episode(10, 13)
    assert_instance_of(IMDb::Episode, episode)
    assert_equal('tt0583457', episode.id)
    assert_equal('http://www.imdb.com/title/tt0583457', episode.url)
    assert_equal(10, episode.season)
    assert_equal(13, episode.episode)
    assert_equal('The One Where Joey Speaks French', episode.title)
    assert_match(/Ross accompanies Rachel to Long Island/, episode.plot)
    assert_equal('2004-02-19', episode.airdate.strftime('%Y-%m-%d'))
    episode = show.get_episode(10, 20)
    assert_equal(10, episode.season)
    assert_equal(20, episode.episode)

    res =  api.search('Seinfeld', :type => 'tt')
    assert(res.length >= 1, 'should return atleast one title')
    seinfeld = api.create(res.first[:id], :load_series => true)
    episode = seinfeld.get_episode(7, 6)
    assert_equal('The Soup Nazi', episode.title)
    assert_equal('1995-11-02', episode.airdate.strftime('%Y-%m-%d'))

    res = api.search('The Americans', :type => 'tt')
    americans = api.create(res.first[:id], :load_series => true)
    episode = americans.get_sorted_episodes.first
    assert_equal(2013, episode.airdate.year)

    res = api.search('Homeland', :type => 'tt')
    homeland = api.create(res.first[:id], :load_series => true)
    assert_equal([], homeland.creator)
    assert_equal([], homeland.director)

    res =  api.search('MASH', :type => 'tt')
    assert(res.length >= 1, 'should return atleast one title')
    mash = api.create(res.first[:id], :load_series => true)
    assert_equal(["Alan Alda", "Wayne Rogers", "Loretta Swit"], mash.actors)
  end

  def test_series_episode_access
    api = IMDb::Api.new
    res =  api.search('MASH', :type => 'tt', :limit => 1)
    series = api.create(res.first[:id], :load_series => true)
    assert_instance_of(IMDb::Series, series)

    # test get_sorted_episodes
    sorted_episodes = series.get_sorted_episodes 
    assert_equal(sorted_episodes.length, series.episodes.length)
    assert_equal(1, sorted_episodes[0].season)
    assert_equal(1, sorted_episodes[0].episode)
    assert_equal(2, sorted_episodes[43].season)
    assert_equal(20, sorted_episodes[43].episode)

    # test get_episode / get_season
    assert_equal(4, series.get_episode(1, 4).episode)
    assert_equal(4, series.get_season(1)[3].episode)

    # test get_last_episode
    last = series.get_last_episode
    assert_equal(11, last.season)
    assert_equal(16, last.episode)

    # test get_next_episode (can't really test this one without breaking in the future)
    assert_equal(nil, series.get_next_episode)

    # test episode count
    assert_equal(251, series.get_episode_count)

    # test future_episode_count
    assert_equal(0, series.get_future_episode_count)
  end

  def test_list_ratings
    api = IMDb::Api.new
    #require 'method_profiler'
    #ratings = api.list('ur22053040')
    # ur22760319
    #log = File.new('brief_test_log', 'w')
    #puts
    #puts
    #profiler = MethodProfiler.observe(IMDb::Title)
    #ratings.each do |id|
    #  next if not id.match /\d+$/
    #  puts "Testing ID #{id}"
    #  begin
    #    entry = api.create(id)
    #    formatter = IMDb::Formatter.new(entry)
    #    brief = formatter.brief
    #    #log << brief + "\n"
    #    #log.flush
    #    puts brief
    #  rescue
    #    puts "An error occured with ID #{id}!"
    #    puts $!
    #    puts $@.join("\n")
    #    #log.close
    #    exit
    #  end
    #end
    #puts profiler.report
    #log.close
    #puts
    #puts

  end
end


