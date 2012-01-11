require 'nokogiri'
require 'open-uri'

def get_table
  $str = open("http://dominion.isotropic.org/leaderboard")
  doc = Nokogiri::HTML($str)
  puts 'getting rows'
  rows = doc.xpath("//tr")
  puts rows.size
  rows = rows.select { |x| x.text =~ /(mharris717|notadam|bossbri)/i }
  puts rows.size
  rows.each { |x| puts x }

  inner_str = rows.map { |x| x.to_s }.join

  res = "<table><tr>"
  %w(_ skill_range rank eligible_games_played nickname).each { |f| res << "<th>#{f}</th>" }
  res << "</tr>"
  res << inner_str
  res << "</table>"
  res
end

require 'sinatra'

get "/" do
  get_table
end



