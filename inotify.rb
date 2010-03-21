# inotify event file/directory monitoring for rbot
# by Matthias -apoc- Hecker <apoc@sixserv.org> -- http://apoc.sixserv.org/
# version 0.0.1 (21/03/2010)

# Please Read:
#   http://wiki.github.com/4poc/rbot-plugins/inotify

# TODO List:
# - deactivate listener when theres no watcher
# - remove watcher when watched directory is deleted
# - ?

begin
  require 'rubygems'
rescue LoadError 
  # ignore LoadError if installed without gems
end

# requires Ruby-FFI <http://wiki.github.com/ffi/ffi/>
begin
  require 'ffi'
rescue LoadError
  raise LoadError, 'Ruby-FFI not found, install it from http://wiki.github.com/ffi/ffi/'
end

##
# FFI Module for accessing inotify kernel subsystem
# copied from the inotify sample code provided by the ffi project:
#   http://github.com/ffi/ffi/blob/master/samples/inotify.rb
##
module Inotify
  extend FFI::Library
  ffi_lib FFI::Library::LIBC
  class Event < FFI::Struct
    layout :wd, :int, :mask, :uint, :cookie, :uint, :len, :uint
  end
  attach_function :init, :inotify_init, [], :int
  attach_function :add_watch,:inotify_add_watch,[:int,:string,:uint], :int
  attach_function :rm_watch, :inotify_rm_watch, [:int, :uint], :int
  attach_function :read, [:int, :buffer_out, :uint], :int
  IN_ACCESS=0x00000001
  IN_MODIFY=0x00000002
  IN_ATTRIB=0x00000004
  IN_CLOSE_WRITE=0x00000008
  IN_CLOSE_NOWRITE=0x00000010
  IN_CLOSE=(IN_CLOSE_WRITE | IN_CLOSE_NOWRITE)
  IN_OPEN=0x00000020
  IN_MOVED_FROM=0x00000040
  IN_MOVED_TO=0x00000080
  IN_MOVE= (IN_MOVED_FROM | IN_MOVED_TO)
  IN_CREATE=0x00000100
  IN_DELETE=0x00000200
  IN_DELETE_SELF=0x00000400
  IN_MOVE_SELF=0x00000800
  # Events sent by the kernel.
  IN_UNMOUNT=0x00002000
  IN_Q_OVERFLOW=0x00004000
  IN_IGNORED=0x00008000
  IN_ONLYDIR=0x01000000
  IN_DONT_FOLLOW=0x02000000
  IN_MASK_ADD=0x20000000
  IN_ISDIR=0x40000000
  IN_ONESHOT=0x80000000
  IN_ALL_EVENTS=( IN_ACCESS | IN_MODIFY | IN_ATTRIB | IN_CLOSE_WRITE | 
                  IN_CLOSE_NOWRITE | IN_OPEN | IN_MOVED_FROM | IN_MOVED_TO |
                  IN_CREATE | IN_DELETE | IN_DELETE_SELF | IN_MOVE_SELF )
end # end module Inotify

##
# InotifyWatch Module for including in InotifyPlugin class
##
module ::InotifyWatch
  # For errors handled explicitly in Watch
  class WatchError < StandardError
  end

  ##
  # A single watch monitor for files or directories
  ##
  class Watch
    attr_accessor :watchlist, :path, :event, :type, :wd
  
    ##
    # Constants For @type: All, File, Directory
    ##
    TYPE_ALL = 1
    TYPE_FILE = 2
    TYPE_DIRECTORY = 3
    
    ##
    # Maps shortcut character to long descriptor and Inotify bitmask value
    ##
    EVENT_MAP = {
      'C' => ['create',             Inotify::IN_CREATE],
      'R' => ['access/read',        Inotify::IN_ACCESS],
      'U' => ['update',             Inotify::IN_MODIFY],
      'A' => ['attribute (change)', Inotify::IN_ATTRIB],
      'M' => ['move',               Inotify::IN_MOVE  ],
      'D' => ['delete',             Inotify::IN_DELETE]
    }
    
    ##
    # path -- absolute path string
    # event -- string or array that describes event
    # type -- integer, string or array for type(all, file, dir)
    # fd -- integer includes file descriptor
    ##
    def initialize(path, event=nil, type=nil, fd=nil)
      # set default values
      event = (event.empty?) ? 'CD' : event
      type  = type || TYPE_ALL
      
      debug " [+] new InModule::InotifyMonitor path(#{path.inspect})" +
            " event(#{event.inspect}) type(#{type.inspect})" +
            " inodeFd(#{fd.inspect})"

      # path could be file or directory but must exists
      if not File.exists? path
        raise WatchError.new 
          'The path does not exist.'
      end
      
      # remove last slash from path
      @path = path.gsub(/\/$/, '')
      
      # parse type and event string if necessary
      @event = parse_event event # resulting in event bitmask
            
      debug " [+] @event(#{@event}) event_str(#{event_str})"
      
      # parse type string into integer TYPE_*
      @type = parse_type type
      
      debug " [+] @type = #{@type} type_str(#{type_str})"
      
      # empty watchlist is default
      @watchlist = [] # contains nicknames or channels

      # initialize watch and file descriptor ...
      @wd = nil
      @fd = nil
      add_watch(fd) if fd
    end

    ##
    # the event_mask and file is parsed and a message string is created. Then
    # the provided procedure is called with the following parameters:
    # targets -- array the watchlist
    # message -- string for notification
    ##
    def process(event_mask, file, notify_targets)
      debug " [+] Watch process" +
            " event_mask(#{event_mask.inspect}) file(#{file.inspect})"

      # do not process event if event is not of correct @type
      is_dir = (event_mask & Inotify::IN_ISDIR) != 0

      debug ' [+] stop process, wrong type' and return if
        ( @type == TYPE_DIRECTORY and not is_dir ) or
        ( @type == TYPE_FILE      and     is_dir )

      message = {
        :type => ((is_dir) ? 'directory' : 'file'),
        :event => event_str(event_mask),
        :path => @path,
        :file => file
      }
      
      debug " [+] Process message for watchlist(#{@watchlist.inspect})" +
            " message(#{message.inspect})"
      
      notify_targets.call(@watchlist, message)
    end

    ##
    # adding a target to the watchlist
    ##
    def add_watchlist(target)
      debug " [+] add target(#{target}) to watchlist of #{@path}"
      @watchlist << target
    end
    
    ##
    # removes a target from the watchlist
    ##
    def remove_watchlist(target)
      @watchlist.delete target
    end

    ##
    # Add watch to Inotify subsystem by provided File Descriptor setting the wd.
    # FD = File Descriptor
    # WD = Watch Descriptor
    ##
    def add_watch(fd)
      @fd = fd
      @wd = Inotify.add_watch(@fd, @path, @event)
      debug " [+] add inotify watch fd(#{@fd})=>path(#{path})" +
            "=>wd(#{@wd})"
    end
    
    ##
    # Remove watch from inotify, identified by @fd 
    # (must set via add_watch first!)
    ##
    def remove_watch
      debug " [+] remove inotify watch fd(#{@fd})=>path(#{@path})" +
            "=>wd(#{@wd})"
      Inotify.rm_watch(@fd, @wd)
    end

    ##
    # return bitmask as human-readable string
    # use @event if event is empty
    ##
    def event_str(event = nil)
      event = @event if not event
      mask_array = []
      EVENT_MAP.each_value do |val| # evtl. .capitalize 
        mask_array << val[0] if (val[1] & event) != 0
      end
      if mask_array.length > 2
        return mask_array[0...-1] * ', ' + ' and ' + mask_array[-1]
      elsif mask_array.length == 2
        return mask_array[0] + ' and ' + mask_array[1]
      elsif mask_array.length == 1
        return mask_array[0]
      else
        return ''
      end
    end
    
    ##
    # return bitmask as short string of characters
    # use @event if event is empty
    ##
    def event_str_short(event = nil)
      event = @event if not event
      str=''
      EVENT_MAP.each_pair do |key, val| # evtl. .capitalize 
        str += key if (val[1] & event) != 0
      end
      return str
    end
    
    def type_str
      return 'F' if @type == TYPE_FILE
      return 'D' if @type == TYPE_DIRECTORY
      return ''
    end
    
    private
    
    ##
    # return a bitmask in inotify format for the given string
    ##
    def parse_event(event)
      # make sure to proceed with array or return valid event string
      if event.class != Array
        event.upcase!
        valid_event = true
        event.split('').each { |i|
          valid_event=false if not EVENT_MAP.has_key? i
        }
      end
      
      # construct the needed "string mask"
      if not valid_event
        event = get_letter_mask(event, EVENT_MAP.keys)
      end
      
      # create bitmask from the "string mask" (@see indices of event map!)
      mask = 0
      event.split('').each do |i|
        mask |= EVENT_MAP[i][1]
      end
      
      return mask
    end

    ##
    # The input string or array can contain anything like 'Files and 
    # Directories' or 'FD' or 'Files' the returned value is a TYPE_* integer.
    ##
    def parse_type(type)
      # if type is a string that contains only valid numbers
      return type.to_i if type.class == String and 
              type.to_i != 0 and (1..3) === type.to_i
      type = get_letter_mask(type, ['F', 'D'])

      _type = TYPE_ALL
      _type = TYPE_DIRECTORY if type.include? 'D'
      if type.include? 'F'
        if _type == TYPE_DIRECTORY
          _type = TYPE_ALL
        else
          _type = TYPE_FILE
        end
      end

      return _type
    end
    
    ##
    # return a string that only contains the first letters of the array
    # the valid array must contain characters that are allowed, all others are
    # ignored. the word 'and' is ignored.
    ##
    def get_letter_mask(array, valid_array)
        array = array.split(/[ ,\.:;\-+]/) if array.class != Array
        
        str = ''
        array.each do |word|
          word.upcase!
          next if word == 'AND'
          str += word[0].chr if valid_array.include? word[0].chr
        end
        return str
    end
    
  end ### end class Watch
  
  
  ##
  # This class represents a single thread that watches for all existing 
  # watchers. You must provide the watchers array and the message procedure
  # that is called within the event notification.
  ##
  class WatchThread
    attr_reader :fd
        
    ##
    # do not start the thread, just setting up
    ##
    def initialize(watchers, notify_targets)
      @watchers = watchers
      @notify_targets = notify_targets

      @fd = nil
      @thread = nil
    end
    
    ##
    # start the watch thread if it isn't running already
    ##
    def start
      return if @thread
      @thread = Thread.start do
        @fd = Inotify.init
        
        @watchers.each do |watch|
          watch.add_watch(@fd)
        end

        @filePtr = FFI::IO.for_fd(@fd)
        while true
          debug " [+] @watch_thread listening for inotify events"
          
          buffer = FFI::Buffer.alloc_out(Inotify::Event.size + 4096, 1, false)
          event = Inotify::Event.new buffer
          ready = IO.select([@filePtr], nil, nil, nil)
          n = Inotify.read(@fd, buffer, buffer.total)

          event_wd = event[:wd]
          event_mask = event[:mask]
          event_len = event[:len]

          debug " [+] meta event message ignored." and next if event_len == 0
          
          # the filename is set after the event datastructure(16 bytes fixed)
          event_file = buffer.get_string(16) # 16 bytes offset

          debug " [+] raw event notification wd(#{event_wd.inspect}) " + 
                "len(#{event[:len]}) mask(#{event_mask}) " +
                "subject(#{event_file.inspect})"

          @watchers.each do |watch|
            # process only if watch descriptor matches
            if event_wd == watch.wd
              watch.process(event_mask, event_file, @notify_targets)
            end
          end
        end
        debug " [+] the watch thread is terminated."
      end # end thread
    end # end start
    
    ##
    # This as cleanly as possible stops the inotify subsystem listener
    # It removes all watchers and then closes the inotify file descriptor
    ##
    def stop
      debug " [+] interrupt watch_thread [@filePtr.closed?(#{@filePtr.closed?})]"
      @thread.raise Interrupt # this should interrupt the thread while
      
      # removing all monitors from running inotify this sends events for each
      #   removed inotify watch
      debug " [+] stop @watchers(#{@watchers.length})"
      @watchers.each do |watch|
        watch.remove_watch
      end
      @filePtr.close if not @filePtr.closed?
      debug " [+] i've closed the inotify FD closed=(#{@filePtr.closed?})"
      
      # make sure @thread is REALLY closed otherwise kill it
      if @thread.alive?
        debug " [+] WARNING: thread is not cleanly stopped I must terminate!"
        @thread.terminate!
      end
      @filePtr = nil
      @thread = nil
    end
    
    ##
    # return true if the thread is running, false if not and also false if fd 
    # is not initialized.
    ##
    def alive?
      return false if not @thread or not @fd
      @thread.alive?
    end
  end # end class WatchThread

end # end module InotifyWatch

##
# the plugin implementation includes the InotifyWatch module and implements 
# rbot commands.
##
class InotifyPlugin < Plugin
  Config.register(Config::BooleanValue.new('inotify.show_hidden',
    :default => false,
    :desc => "Whether to display events of hidden(/dotfiles) files/directories."))
  Config.register(Config::StringValue.new('inotify.event_format',
    :default => '[inotify] %TYPE% %EVENT%: %PATH%/%FILE%',
    :desc => "The format template for the event notification."))
  
  def help(plugin,topic="")
    case topic
    when "status"
      "inotify status : shows the status of the inotify event listener"
    when "events"
      "inotify events : lists all supported inotify events a watch can listen for"
    when "show", "list"
      "inotify show|list : lists all inotify event watchers/listener"
    when "addwatch"
      "inotify addwatch #{Bold}path#{Bold} [for #{Bold}events#{Bold}] [of #{Bold}file|dir#{Bold}] : create a inotify event listener does not add a channel or nickname for watching"
    when "rm", "remove", "delete"
      "inotify remove|delete #{Bold}path#{Bold} : remove a inotify event listener"
    when "watch"
      "inotify watch #{Bold}path#{Bold} [for #{Bold}events#{Bold}] [of #{Bold}file|dir#{Bold}] : create a inotify event listener and add current channel/nickname to watchlist"
    when "who watches"
      "inotify who watches #{Bold}path#{Bold} : shows all channels and nicknames that are watching the path"
    when "unwatch", "rmwatch"
      "inotify unwatch|rmwatch #{Bold}path#{Bold} : remove the current channel/nickname from watchlist"
    else
      "filesystem event listener: inotify status|events|show|list|addwatch|rm|remove|delete|watch|who watches|unwatch|rmwatch"
    end
  end

  ##
  # includes the Watch and WatchThread classes inside the plugin class.
  ##
  include InotifyWatch
  
  def initialize
    super
    
    ##
    # Load inotify watchers from registry if it is not set the watchers will
    # initialize a empty array.
    ##
    if @registry.has_key?('inotify') and @registry['inotify']
      @watchers = @registry['inotify']
      raise LoadError, "corrupted inotify monitor database" unless @watchers
    else
      @watchers = [ ]
    end
    
    @watch_thread = nil
    start_watch_thread
  end
    
  def start_watch_thread
    return if @watch_thread and @watch_thread.alive?
    @watch_thread.stop and @watch_thread = nil if @watch_thread
    notify_targets = lambda do |targets, message|
      # ignore hidden files / dotfiles if config value is false
      if not @bot.config['inotify.show_hidden'] and message[:file][0].chr == '.'
        debug ' [+] stop process, hidden file'
        return
      end

      message_str = @bot.config['inotify.event_format'].dup
      replacement = {
        '%TYPE%'  => message[:type],
        '%EVENT%' => message[:event],
        '%PATH%'  => message[:path],
        '%FILE%'  => message[:file]
      }
      replacement.each_pair do |template, replace|
        message_str[template] = replace if message_str.include? template
      end
      
      targets.each do |target|
        @bot.say(target, message_str) 
      end
    end
    @watch_thread = WatchThread.new(@watchers, notify_targets)
    
    @watch_thread.start
  end

  def save
    debug " [+] save #{@watchers.length} watchers"
    @registry['inotify'] = @watchers
  end
  
  def cleanup
    debug " [+] plugin cleanup called"
    @watch_thread.stop
    @watch_thread = nil
    @watchers = nil
    super
  end
  

  ##
  # Create a new watch without adding the current channel or query to the
  # watchlist besides that it is exactly the same as watch.
  ##
  def add_watch(m, params)
    path  = params[:path ]
    event = params[:event]
    type  = params[:type ]
    m.reply "no such file or directory: #{path}" and return if not File.exists? path

    # tries to find watch with specified path and skip if found
    watch = watch_lookup path
    if watch
      debug " [+] watch existing skipping"
      return
    end
    
    debug " [+] create new Watch"
    watch = Watch.new(path, event, type, @watch_thread.fd)
    @watchers << watch
    
    m.reply "add event listener for #{path} do not add channel/nickname to watchlist."
  end
  
  ##
  # @see addwatch does exactly the same but it adds the current channel or query
  # to the watchlist of the specified path. If the path is not existing, it will
  # be created.
  ##
  def watch(m, params)
    source = m.replyto.to_s
    path  = params[:path ]
    event = params[:event]
    type  = params[:type ]
    m.reply "no such file or directory: #{path}" and return if not File.exists? path

    # check if already there, if so test if already watched, if not add
    watch = watch_lookup path
    if watch
      debug " [+] watch existing: make sure source(#{source}) is in watchlist"
      if watch.watchlist.include? source
        debug " [+] watch(#{path}) watching already"
      else
        watch.add_watchlist source
      end
      return
    end
    
    debug " [+] create new Watch"
    watch = Watch.new(path, event, type, @watch_thread.fd)
    watch.add_watchlist source
    @watchers << watch
    
    m.reply "add event listener for #{path} and add #{source} to watchlist."
  end

  def who_watches(m, params)
    path = params[:path]
    watch = watch_lookup path
    m.reply 'no one watches %s' % path and return if not watch or
            watch.watchlist.empty?
    m.reply "#{path} watched by #{watch.watchlist.join(', ')}"
  end
  
  ##
  # removes the given path from the watchlist
  ##
  def remove_watchlist(m, params)
    path = params[:path]
    source = m.replyto.to_s
    watch = watch_lookup path
    m.reply "path #{path} not found" and return if not watch
    
    if not watch.watchlist.include? source
      m.reply "path #{path} not watched by #{source}"
      return
    end
    
    monitor.remove_watchlist(source)
    m.reply "removed #{source} from watchlist for #{path}"
  end
  
  ##
  # remove path watch
  ##
  def remove(m, params)
    path = params[:path]
    watch = watch_lookup path
    m.reply "path #{path} not found" and return if not watch
    
    # stop monitor's inotify event listening
    watch.remove_watch
    @watchers.delete watch
    m.reply "monitor for path #{path} deleted"
  end
  
  def list(m, params)
    m.reply 'no watches' and return if not @watchers or @watchers.empty?
    source = m.replyto.to_s
    
    arr = []
    @watchers.each do |watch|
      type_str = ''
      type_str = watch.type_str + ':' if not watch.type_str.empty?
      str  = "#{watch.path} (#{type_str}#{watch.event_str_short})"
      str += " (watched)" if watch.watchlist.include? source
      arr << str
    end
    m.reply "monitored: #{arr.join ', '}"
  end
  
  def events(m, params)
    event_types = []
    Watch::EVENT_MAP.each_pair do |short, long|
      long = long.first
      event_types << "#{long} [#{short}]"
    end
    m.reply "you can specify one or more of the following event types: #{event_types.join(' | ')}"
    m.reply "examples: 'create, update', 'create and update' 'CU' (all meaning the same)"
  end
  
  def status(m, params)
    if @watch_thread.alive?
      m.reply 'the inotify event notification is listening'
    else
      m.reply 'inotify event thread not running (try to rescan), report with debug log please'
    end
  end
  
  private

  def watch_lookup(path)
    @watchers.each do |watch|
      return watch if watch.path == path
    end
    return nil
  end
  
end # end class InotifyPlugin

plugin = InotifyPlugin.new

# the default security setting is that only the owner can show or modify watches
plugin.default_auth('show', false)
plugin.default_auth('modify', false)

plugin.map('inotify addwatch [*type in] :path [for *event]',    :action => 'add_watch', :auth_path => 'modify')
plugin.map('inotify addwatch [for *event] [of *type in] :path', :action => 'add_watch', :auth_path => 'modify')
plugin.map('inotify addwatch [for *event] in :path',            :action => 'add_watch', :auth_path => 'modify')
plugin.map('inotify addwatch :path [for *event] [of *type]',    :action => 'add_watch', :auth_path => 'modify')

plugin.map('inotify watch [*type in] :path [for *event]',    :action => 'watch', :auth_path => 'modify')
plugin.map('inotify watch [for *event] [of *type in] :path', :action => 'watch', :auth_path => 'modify')
plugin.map('inotify watch [for *event] in :path',            :action => 'watch', :auth_path => 'modify')
plugin.map('inotify watch :path [for *event] [of *type]',    :action => 'watch', :auth_path => 'modify')

plugin.map('inotify who watches :path', :action => 'who_watches', :auth_path => 'show')

plugin.map('inotify unwatch :path', :action => 'remove_watchlist', :auth_path => 'modify')
plugin.map('inotify rmwatch :path', :action => 'remove_watchlist', :auth_path => 'modify')

plugin.map('inotify rm :path',     :action => 'remove', :auth_path => 'modify')
plugin.map('inotify remove :path', :action => 'remove', :auth_path => 'modify')
plugin.map('inotify delete :path', :action => 'remove', :auth_path => 'modify')

plugin.map('inotify list', :action => 'list', :auth_path => 'show')
plugin.map('inotify show', :action => 'list', :auth_path => 'show')

plugin.map('inotify events', :action => 'events')

plugin.map('inotify status', :action => 'status')

