
class DfPlugin < Plugin
  def help(topic)
    return "df: return total, used and free system space."
  end
  
  def df(m, params)
    df_total = `df --total | tail -n1`
    if df_total.match /total\s+(\d+)\s+(\d+)\s+(\d+)/
     used = $2.to_i / 1024.0 / 1024.0
     free = $3.to_i / 1024.0 / 1024.0
     total = used + free
     m.reply("total: #{total.round} GiB used: #{used.round} GiB free: #{free.round} GiB")
    end
  end
end
plugin = DfPlugin.new
plugin.map 'df'
