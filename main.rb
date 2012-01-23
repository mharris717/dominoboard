require 'nokogiri'
require 'open-uri'
require 'mharris_ext'
require 'andand'

gem 'mongoid','2.0.1'
require 'mongoid'

class String
  def rpad(n)
    return self if length >= n
    pad = " "*(n-length)
    "#{self}#{pad}"
  end
end

Mongoid.configure do |config|
  name = "dominoboard_dev"
  host = "localhost"
  config.master = Mongo::Connection.new(host).db(name)

  config.persist_in_safe_mode = false
end

class Ranking
  include Mongoid::Document
  include Mongoid::Timestamps
  field :skill, :type => Float
  field :stdev, :type => Float
  field :username
  field :rank, :type => Fixnum
  field :games_played, :type => Fixnum
  field :batch_dt, :type => Time
  def rating_str
    "#{skill} +- #{stdev}"
  end
  def self.create_from_row!(row,batch_dt)
    res = new(:batch_dt => batch_dt)
    tds = row.xpath("td").map { |x| x.text.strip }
    raise "bad tds size #{tds.size} #{row.text}" unless tds.size == 5
    res.skill, res.stdev = *tds[1].split(" ").reject { |x| x.length < 3 }.map { |x| x.to_f }
    res.rank, res.games_played, res.username = *tds[2..4]
    res.save!
    res
  end
end

class LatestRanking
  class << self
    fattr(:instance) { new }
    def method_missing(sym,*args,&b)
      instance.send(sym,*args,&b)
    end
  end

  fattr(:batch_dt) do
    Ranking.order_by([:batch_dt, :desc]).limit(1).first.batch_dt
  end
  fattr(:cached_rankings) do
    Ranking.where(:batch_dt => batch_dt)
  end
  def rankings
    #batch_dt!
    #cached_rankings! if cached_rankings.first.batch_dt != batch_dt
    cached_rankings
  end
  fattr(:ranking_hash) do
    res = {}
    rankings.each do |r|
      res[r.username] = r.rating_str
    end
    res
  end
  def get_rating(username)
    #rankings.select { |x| x.username == username }.first.andand.skill
    ranking_hash[username]
  end
end

class Game
  include Mongoid::Document
  include Mongoid::Timestamps
  field :game_id
  field :winner
  field :loser
  field :players, :type => Array
  field :game_dt, :type => Time
  field :game_log
  field :filled, :type => Boolean
  #game-20120117-200600-93875d32
  def url
    "http://councilroom.com/game?game_id=#{game_id}.html"
  end
  def fill_from_remote!
    self.game_log = open(url).read if self.game_log.blank?
    doc = Nokogiri::HTML(game_log)
    bolds = doc.xpath("//b")
    self.winner = bolds.find { |x| x.text =~ /#1 / }.text[3..-1]
    self.loser = bolds.find { |x| x.text =~ /#2 / }.text[3..-1]
    self.players = [winner,loser]
  rescue => exp
    puts "error #{exp.message}"
  ensure
    self.filled = true
    save!
  end
  def fill_game_dt!
    raise "bad" unless game_id =~ /game-(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})/
    args = [$1,$2,$3,$4,$5].map { |x| x.to_i }
    self.game_dt = Time.local(*args)
  end
  before_create "fill_game_dt!"
  scope :needs_fill, where(filled: nil)
  class << self
    def add!(game_id)
      game_id = game_id.strip
      create!(:game_id => game_id) if where(:game_id => game_id).count == 0
    end
    def add_player!(username)

    end
    def backfill!
      Game.where(:winner => nil, :filled => nil).each do |g|
        g.filled = true
        g.save!
      end
    end
    def fill_remote!
      puts "Needs Fill #{needs_fill.count}"
      needs_fill.limit(10).each { |g| g.fill_from_remote! }
      fill_remote! if needs_fill.count > 0
    end
    def fill_remote_loop!
      loop do
        fill_remote!
        puts "Fill Done"
        sleep(5)
      end
    end
  end
end

class Player
  include FromHash
  attr_accessor :username
  def url
    "http://councilroom.com/search_result?p1_name=#{username}"
  end
  def add_games!
    doc = Nokogiri::HTML(open(url))
    links = doc.xpath("//a").map { |x| x.get_attribute('href') }.select { |x| x =~ /game\?game_id/i }
    links.each do |link|
      raise "unknown #{link}" unless link =~ /game\?game_id=(.*)\.html/i
      Game.add! $1
    end
  end
  def games
    Game.where(:players => username).sort_by { |x| x.game_dt }
  end
  def to_s_history
    wins = losses = 0
    res = games.map do |g|
      opp = (g.players - [username]).first
      rating = LatestRanking.get_rating(opp)
      won = (g.winner == username) ? "Won " : "Lost"
      dt = g.game_dt.strftime("%m/%d")
      if opp == 'mharris717'
        nil
      elsif rating && rating.split(" ").first.to_f >= 24
        
        (g.winner == username) ? wins += 1 : losses += 1
        "#{dt} #{won} vs #{opp.rpad(20)} #{rating}"
      else
        nil
      end
    end.select { |x| x }.join("\n")
    "#{username} #{wins}-#{losses}\n#{res}"
  end

  class << self
    def add_games!(username)
      new(:username => username).add_games!
    end
  end
end


def log_table
  $str = open("http://dominion.isotropic.org/leaderboard")
  doc = Nokogiri::HTML($str)
  puts 'getting rows'
  rows = doc.xpath("//tr")
  puts rows.size

  #rows = rows.select { |x| x.text =~ /(mharris717|notadam|bossbri|lawnboy)/i }
  rows = rows.select { |x| x.text =~ /\d\.\d+/i }
  batch_dt = Time.now
  rows.each do |row|
    Ranking.create_from_row!(row,batch_dt)
  end
end

def get_table
  $str = open("http://dominion.isotropic.org/leaderboard")
  doc = Nokogiri::HTML($str)
  puts 'getting rows'
  rows = doc.xpath("//tr")
  puts rows.size

  rows = rows.select { |x| x.text =~ /(mharris717|notadam|bossbri|lawnboy)/i }


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

if false
  require 'sinatra'

  get "/" do
    get_table
  end
end

if false
  log_table
  puts Ranking.count



  puts LatestRanking.batch_dt
  puts LatestRanking.rankings.size

  #Game.destroy_all

  if false
    Game.add!("game-20120117-193312-3b4edf81")
    g = Game.first
    g.fill_from_remote!
    puts g.players.inspect
  end

  #p = Player.add_games!(:mharris717)

  #puts Game.count
  #puts Game.last.game_dt

  puts Game.all.select { |x| x.winner }.size
  puts Game.all.reject { |x| x.winner }.size

  puts LatestRanking.get_rating('NotAdam')
  File.create("games.txt",Player.new(:username => 'mharris717').to_s_history)
end

def fixed_username(n)
  if n =~ /(.*)(\u25B2|\u25BC)/i
    $1.strip
  else
    n
  end
end

c = "\u25B2"
puts c
names = LatestRanking.ranking_hash.keys.select { |x| x =~ /adam/i }
puts names.inspect
File.create("games.txt",Player.new(:username => 'mharris717').to_s_history)

if false
  Ranking.all.each do |r|
    r.username = fixed_username(r.username)
    r.save!
  end
end