require 'rubygems'
require 'mechanize'

class GithubCalPlugin < Plugin
  def gitcal(m, params)
    agent = Mechanize.new
    url = "http://calendaraboutnothing.com/~#{params[:user]}"

    page = agent.get url

    num = page.search '.longest_streak a .num'
    streak = num.first.content.split("\n").map({ |s| s.strip! }).join ' '

    num = page.search '.current_streak .num'
    streak_current = num.first.content.split("\n").map({ |s| s.strip! }).join ' '

    m.reply "Calendar about nothing.. current/longest streak:#{streak_current}/#{streak}(#{url})"
  end
end

plugin = GithubCalPlugin.new
plugin.map "gitcal :user", :action => 'gitcal', :thread => true

