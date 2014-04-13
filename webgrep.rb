# rbot plugin: webgrep v0.1 grep in websites
# Copyright (C) 2014  Matthias -apoc- Hecker <apoc@sixserv.org>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

require 'mechanize'

class WebGrepPlugin < Plugin
  attr_accessor :lasturl
  def help(plugin, topic='')
    return "grep [URL] <REGEXP[ REGEXP[...]]> | matches regular expressions in specified URL, or last URL mentioned"
  end

  def grepurl(url, words=[])
    return if words.empty?
    agent = Mechanize.new
    agent.user_agent_alias = 'Linux Mozilla'
    page = agent.get url
    title = page.title
    content = page.search('body').inner_html
    content.gsub! %r{<br[^>]*>}, "\n"
    content.gsub! %r{<p[^>]*>}, "\n"
    content.gsub! %r{<div[^>]*>}, "\n"
    content.gsub! %r{<[^>]*>}, ''
    found_line = nil
    content.split("\n").each do |line|
      include_all = true
      words.each do |word|
        #if not line.downcase.include? word.downcase
        if not line.match /#{word}/i # downcase.include? word.downcase
          include_all = false
          next
        end
      end
      if include_all
        found_line = line.strip
        break
      end
    end
    return [title, found_line]
  end
  
  def grep(m, params)
    url = params[:url]
    words = params[:words]

    if not url.match /^http/
      words << url
      url = @lasturl
    end

    res = nil
    begin
      res = grepurl(url, words)
    rescue
      debug $!
    end
    if not res
      m.reply 'unable to grep this website :('
      return
    end
    title, result = res
    if not result
      m.reply 'words not found on that page :('
      return
    end
    words.each do |word|
      result.gsub!(/(#{word})/i, Bold+'\\1'+NormalText)
    end
    def format(result, title)
      return '»' + result + '« — ' + Bold + Color + ('%02d' % ColorCode[:yellow]) + title + NormalText
    end
    len = format(result, title).length
    if len + 44 > 512
      result = result[0...result.length-(len + 44 - 512)] + Bold.to_s + '…' + NormalText.to_s
    end
    m.reply format(result, title)
  end

  def message(m)
    if m.message.match /(http[s]?:\/\/.*)/
      @lasturl = $1
    end
  end
end
plugin = WebGrepPlugin.new
plugin.map 'grep :url [*words]', :action => :grep

