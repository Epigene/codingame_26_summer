# frozen_string_literal: true

# This script reads the `build_order.txt` file thats placed in the same dir as this script file
# and concatenates the file contents, in order, into a "codingame.rb" file in the same dir.

# Call by running `$ ruby codingame_concatenator.rb` in console

require "pry"

concatenable_file_list_path = Pathname.new("./build_order.txt")
output_path = Pathname.new("./CODINGAME.rb")

File.open(output_path, "w") do |file|
  File.readlines(concatenable_file_list_path).each do |addable_file_line|
    addable_file_name = addable_file_line.split("#").first.strip
    contents = File.read(Pathname.new("./#{addable_file_name}"))

    file.write("#{contents}\n")
  end
end

puts(
  "Concatenated contents of files mentioned in #{concatenable_file_list_path} " \
  "into #{output_path}"
)
