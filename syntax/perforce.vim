" Perforce form/spec buffers (e.g. `p4 change -o`)
if exists("b:current_syntax")
  finish
endif

syntax match p4Comment "^#.*$"
syntax match p4Header "^[A-Za-z]\+:"

highlight default link p4Comment Comment
highlight default link p4Header Keyword

let b:current_syntax = "perforce"
