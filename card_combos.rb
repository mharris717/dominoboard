require 'mongoid'
require 'json'
require 'open-uri'
require 'pp'

class Payload
  include Mongoid::Document
  include Mongoid::Timestamps

  field :url
  field :raw_payload
  field :payload, :type => Hash

  before_save :set_parsed_payload!

  def set_parsed_payload!
    self.payload = JSON.parse(raw_payload) if raw_payload
  rescue
  end

  class << self
    def save_url(url)
      str = open(url).read
      obj = new(:url => url, :raw_payload => str)
      obj.save!
      obj
    end

    def get(url)
      puts "URL: #{url.inspect}"
      where(:url => url).first || save_url(url)
    end
  end
end

class CardProb
  include Mongoid::Document
  include Mongoid::Timestamps

  field :card1
  field :card2
  field :win_prob, :type => Float
  field :base_chances, :type => Float
  field :cards, :type => Array

  field :win_prob_c1, :type => Float
  field :win_prob_c2, :type => Float
  field :norm_c2_win_factor, :type => Float

  before_save :set_cards_array!

  def set_cards_array!
    self.cards = [card1,card2].select { |x| x.present? }
  end

  def to_s
    w = win_prob.to_s[0..5]
    "#{card1} #{card2} #{w} in #{base_chances} #{norm_c2_win_factor.to_s[0...4]}"
  end

  def has_prize?
    SpecialCards.include_any?(card1,card2)
  end

  def <=>(cp)
    win_prob <=> cp.win_prob
  end

  def mod_win_prob_for_card(card)
    return 1 unless card2
    return 1 if card1 == card2
    other = (cards - [card]).first
    other_prob = klass.all_hash[[card]]
    win_prob / other_prob
  end

  def raw_c2_win_factor
    win_prob / win_prob_c2
  end
    
  attr_accessor :ranks

  class << self
    def make_for_card1_inner(card1,all_probs)
      all_probs.each do |card2,card_probs|
        h = card_probs["win_weighted_gain"]
        prob = h[1]/h[0]
        create!(:card1 => card1, :card2 => card2, :win_prob => prob, :base_chances => h[0])
      end
    end
    def make_for_card1(card1)
      url = cond_url(card1)
      probs = Payload.get(url).payload
      make_for_card1_inner(card1,probs)
    end
    def make_base
      probs = Payload.get(BASE_URL).payload
      probs.each do |card1,card_probs|
        h = card_probs["win_weighted_gain"]
        prob = h[1]/h[0]
        create!(:card1 => card1, :card2 => nil, :win_prob => prob, :base_chances => h[0])
      end
    end
    def make_all!
      destroy_all
      all_cards.each do |c|
        make_for_card1(c)
      end
      make_base
    end

    fattr(:all_hash) do
      res = {}
      all.each do |p|
        res[p.cards] = p.win_prob
      end
      res
    end

    def set_base_probs!
      all.select { |x| x.card1 && x.card2 }.each do |prob|
        prob.win_prob_c1 = all_hash[[prob.card1]]
        prob.win_prob_c2 = all_hash[[prob.card2]]
        prob.save!
      end
    end
    def set_normalized_win_factor!
      all_cards.each do |c|
        probs = where(:card1 => c).select { |x| x.card2 && !x.has_prize? }
        if probs.size > 0
          avg = probs.map { |x| x.raw_c2_win_factor }.avg
          probs.each do |prob|
            prob.norm_c2_win_factor = prob.raw_c2_win_factor / avg
            prob.save!
          end
        end
      end
    end
  end
end

class Array
  def avg
    sum.to_f / size.to_f
  end
end

class Kingdom
  include FromHash
  fattr(:cards) { [] }
  fattr(:probs) do
    cards.map do |c1|
      cards.map do |c2|
        CardProb.where(:card1 => c1, :card2 => c2).first
      end
    end.flatten.sort
  end
  def self.random
    c = all_cards.reject { |x| SpecialCards.include?(x) }.sort_by { |x| rand() }[0...10]
    new(:cards => c)
  end
end

BASE_URL = "http://councilroom.com/supply_win_api?dev=mharris717"

def cond_url(card)
  card = card.gsub(" ","%20")
  "#{BASE_URL}&cond1=#{card}"
end

def all_cards
  Payload.get(BASE_URL).payload.keys.sort
end

def fetch_payloads!
  all_cards.each do |c|
    url = cond_url(c)
    Payload.get(url)
  end
end


module SpecialCards
  class << self
    def prizes
      ['Followers','Trusty Steed','Bag of Gold','Diadem','Princess']
    end
    def victory
      ['Colony','Province','Duchy','Estate']
    end
    def money
      ['Platinum','Gold','Silver','Copper']
    end
    def all
      prizes + victory + money + ['Archivist','Curse']
    end
    fattr(:all_hash) do
      all.inject({}) { |h,c| h.merge(c => true) }
    end
    def include?(c)
      all_hash[c]
    end
    def include_any?(*cs)
      [cs].flatten.any? { |c| include?(c) }
    end
  end
end

class Array
  def rank_hash
    res = {}
    each_with_index do |obj,i|
      res[obj] = i
    end
    res
  end
end

class Card
  include FromHash
  attr_accessor :name

  fattr(:probs) do
    res = all_probs.select { |x| x.card1 == name && x.card2 }.sort_by { |x| x.win_prob }.reverse
    #raise "no probs for #{name}" if res.size == 0
    res
  end

  fattr(:prob_rank_hash) do
    probs.rank_hash
  end

  fattr(:base_prob) do
    CardProb.all_hash[[name]]
  end

  fattr(:ordered_probs) do
   # raise "foo" if probs.size == 0
    res = []
    prob_rank_hash.each do |prob,rank|
      #if prob.card2
        base = klass.base_ranks[prob.card2]
        raise prob.inspect unless base
        prob.ranks = [base,rank]
        res << [base-rank,prob]
      #end
    end
    res.sort_by { |x| x[0] }.map { |x| x[1] }.reverse
  end

  def best_prob
    ordered_probs.last
  end


  def to_s
    other = (best_prob.cards - [name]).first
    "#{name} with #{other} #{best_prob.win_prob.to_s[0..4]} #{best_prob.ranks.inspect}"
  end

  class << self
    fattr(:all) do
      all_cards.map { |x| new(:name => x) }
    end
    fattr(:all_hash) do
      res = {}
      all.each { |c| res[c.name] = c }
      res
    end
    fattr(:base_ranks) do
      all.sort_by { |x| x.base_prob }.map { |x| x.name }.reverse.rank_hash
    end
  end
end

def all_probs
  $all_probs ||= CardProb.all.map { |x| x }.select { |x| x.base_chances >= 1000 }.reject { |x| x.has_prize? }.sort_by { |x| x.win_prob }.reverse
end

#CardProb.make_all!

#Card.all!

if false

  puts all_probs.size
  all_probs.reverse[0...20].each do |p|
    #puts p
  end

  #pp Payload.get(BASE_URL).payload['Mountebank']

  #k = Kingdom.new(:cards => ['Menagerie','Monument','Ghost Ship','Inn','Goons','Tunnel',"Worker's Village",'Governor','Adventurer','Grand Market'])
  #k.probs.each { |x| puts x }

  Card.all.select { |x| x.best_prob }.each do |c|
    #puts c
  end

  puts Card.base_ranks['Grand Market']

  Card.all.find { |x| x.name == 'Silk Road' }.ordered_probs.each do |p|
    #puts "#{p} #{p.ranks.inspect}"
  end

  all = Card.all.map { |x| x.ordered_probs }.flatten

  str = []
  str << ['Card1','Card2','Win Prob','Base Rank','Pair Rank','Rank Diff'].join(",")
  all.select { |x| x.ranks }.sort_by { |x| x.ranks[0] - x.ranks[1] }.each do |p|
    #str << "#{p} #{p.ranks.inspect}"
    str << [p.card1,p.card2,p.win_prob,p.ranks[0],p.ranks[1],p.ranks[0]-p.ranks[1]].join(",")
  end
  str = str.join("\n")
  File.create("cards.csv",str)
end

#CardProb.set_base_probs!

p = CardProb.where(:card1 => "Grand Market", :card2 => "Thief").first
puts p.inspect

CardProb.where(:card1 => "Fool's Gold").select { |x| x.card2 && !x.has_prize? }.sort_by { |x| x.win_prob / x.win_prob_c2 }.reverse.each do |p|
  d = p.win_prob / p.win_prob_c2
  #puts "#{p.card2} #{p.win_prob.to_s[0...4]} #{p.win_prob_c2.to_s[0...4]} #{d.to_s[0...4]} #{p.norm_c2_win_factor.to_s[0...4]}"
end

CardProb.order_by([[:norm_c2_win_factor,:desc]]).limit(100).reject { |x| x.has_prize? }[0...3].each do |p|
  #puts "#{p.card1} #{p.card2} #{p.win_prob.to_s[0...4]}, Base #{p.win_prob_c2.to_s[0...4]}, Factor #{p.norm_c2_win_factor.to_s[0...4]}"
end

#CardProb.set_normalized_win_factor!

k = Kingdom.random
puts k.cards.inspect

a = k.probs.sort_by { |x| x.norm_c2_win_factor }.reverse
a = a[0...10] + a[-10..-1]
gets
a.each { |x| puts x }

puts "\n\n\n"

a = k.probs.sort_by { |x| x.win_prob }.reverse
a = a[0...10] + a[-10..-1]
gets
a.each { |x| puts x }



