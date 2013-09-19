
class FingerprintPlugin < Plugin
    Config.register Config::StringValue.new('fp.default_name',
      :default => nil,
      :desc => "Default fingerprint name to show.")

  def help(plugin, topic=nil)
    'simple certificate fingerprint database: fingerprint|fp [name] | fpart [name] | fplist | fpadd [name] [fingerprint] | fpdel [name]'
  end

  def fp(m, params)
    name = params[:name] || @bot.config['fp.default_name']
    m.reply 'not found, try fplist' and return if not @registry.has_key? name

    owner, fingerprint = @registry[name]
    m.reply "#{Bold}#{name}#{NormalText} (#{owner}): #{Underline}#{fingerprint}#{NormalText}"
  end

  def fpart(m, params)
    name = params[:name] || @bot.config['fp.default_name']
    m.reply 'not found, try fplist' and return if not @registry.has_key? name

    owner, fingerprint = @registry[name]
    m.reply "IMPLEMENT ME!11! :P"
  end

  def fplist(m, params)
    list = @registry.keys
    if list.length > 0
      m.reply list.join(', ')
    else
      m.reply 'no fingerprints yet, add one using fpadd [name] [fingerprint]'
    end
  end

  def fpadd(m, params)
    name = params[:name]
    fingerprint = params[:fingerprint].join ' '
    if @registry.has_key? name
      owner, fp = @registry[name]
      if m.source.to_s != owner
        m.reply 'only %s can modify fingerprint %s' % [owner, name]
        return
      end
    end

    #add fingerprint
    @registry[name] = [m.source.to_s, fingerprint]
    m.reply "Fingerprint #{Bold}#{name}#{NormalText}: #{Underline}#{fingerprint}#{NormalText} added."
  end

  def fpdel(m, params)
    name = params[:name] || @bot.config['fp.default_name']
    m.reply 'not found, try fplist' and return if not @registry.has_key? name
    owner, fp = @registry[name]
    if m.source.to_s != owner
      m.reply 'only %s can modify fingerprint %s' % [owner, name]
      return
    end

    owner, fingerprint = @registry[name]
    @registry.delete name
    m.reply "Fingerprint #{Bold}#{name}#{NormalText}: #{Underline}#{fingerprint}#{NormalText} deleted."
  end
end
plugin = FingerprintPlugin.new
plugin.map 'fingerprint [:name]', :action => 'fp'
plugin.map 'fp [:name]', :action => 'fp'
plugin.map 'fpart [:name]'
plugin.map 'fplist'
plugin.map 'fpadd :name *fingerprint'
plugin.map 'fpdel :name'

