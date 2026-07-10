require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << File.expand_path("~/ghq/github.com/dcluna/dotfiles/bin/magit-auto-detach")
  t.test_files = FileList["test/**/*_test.rb"]
end

task default: :test
