# The README's demo, recorded with https://github.com/charmbracelet/vhs against
# a small Rails shop app with 291 Minitest tests. Run `vhs riptide-demo.tape`
# from the app's root, with the app committed to git.
Output riptide-demo.gif

Set Shell "bash"
Set FontSize 18
Set Width 1200
Set Height 720
Set Padding 24
Set Theme "Catppuccin Mocha"
Set TypingSpeed 45ms
Set WindowBar Colorful

Hide
Type "export PS1='$ ' && git checkout -q app/models/order.rb && rm -rf tmp/riptide && clear"
Enter
Show

Type "bin/rails test"
Sleep 300ms
Enter
Sleep 6s

Hide
Type "sed -i '' 's/line_items.sum(&:subtotal_cents)/line_items.map(\&:subtotal_cents).sum/' app/models/order.rb && clear"
Enter
Show

Type "git --no-pager diff"
Sleep 300ms
Enter
Sleep 3s

Type "bin/rails test"
Sleep 300ms
Enter
Sleep 5s

Hide
Type "git checkout -q app/models/order.rb"
Enter
