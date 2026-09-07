# Condinbot
Not a gem! A sandbox where to develop bots for codingame in TDD manner, in separate, testable files.
This one is an entry for Codingame 2026 Summer challenge (Back Track King)

## Use
1. Place files in `lib/`, and require them in `lib/codinbot.rb` like you normally would.
2. Write specs in `spec/`
3. Configure `build_order.txt` contents.
  3.1 `requires.rb`, `game_init.rb`, and `game_loop.rb` will be necessary for all bots
  3.2 `grid.rb` often is useful for 2d cell-based navigation
4. When you're ready to sync to codingame, run `$ ruby codingame_concatenator.rb`

## License

The code is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
