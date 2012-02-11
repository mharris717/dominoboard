load 'main.rb'

task :fill_remote do
  log_table
  fix_usernames!
  get_our_games
  Game.fill_remote!
  write_games!
end