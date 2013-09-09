# PROOF OF CONCEPT -- might destroy everything/something
#  just to show the idea.

class RegistryBackup < Plugin
  def import(m, params)
    filename = params[:filename]
    backup = File.open(filename) do |file|
      Marshal.load(file)
    end

    m.reply('import %d keys registery backup, %s' % [
            backup.keys.length,
            filename
    ])

    backup.each_key do |key|
      plugin_name = key[0...key.index('.')]
      key = key[(plugin_name.length + 1)..-1]

      debug 'restore [%s] %s..' % [plugin_name, key]
      @bot.plugins[plugin_name].registry[key] = backup[key]
    end

    m.reply 'import complete.'
  end

  def export(m, params)
    backup = {} # obviously not like that (in-chunks not everything in memory)

    filename = params[:filename] || File.join(@bot.path, Time.now.strftime('backup_%Y-%m-%d_%H%M%S.dat'))
    plugins = @bot.plugins.core_modules + @bot.plugins.plugins
    m.reply('export %d/%d (%d) plugin registery backup, %s' % [
           @bot.plugins.core_modules.length, @bot.plugins.plugins.length,
           @bot.plugins.core_modules.length + @bot.plugins.plugins.length,
           filename
    ])

    plugins.each do |plugin_name|
      plugin = @bot.plugins[plugin_name]

      plugin.registry.each_key do |key|
        value = plugin.registry[key]
        key = '%s.%s' % [plugin_name, key]

        backup[key] = value
        debug 'set key'
      end
    end

    File.open(filename, 'w') do |file|
      Marshal.dump(backup, file)
    end

    m.reply 'export done %d bytes.' % File.size(filename)
  end

  def name
    'backup'
  end
end

plugin = RegistryBackup.new
plugin.map 'import :filename', :threaded => true
plugin.map 'export [:filename]', :threaded => true

