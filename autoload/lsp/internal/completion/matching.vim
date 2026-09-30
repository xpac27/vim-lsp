" Annotate private records with {matched, score}; never modify an LSP item.
" Both ranking and fuzzy filtering use this matcher so that labels, whitespace
" and the fallback for older Vim/Neovim versions have the same meaning.
function! lsp#internal#completion#matching#score(records, base, fuzzy) abort
    for l:record in a:records
        let l:record['matched'] = empty(a:base)
        let l:record['score'] = 0
    endfor
    if empty(a:base)
        return
    endif

    if a:fuzzy && exists('*matchfuzzypos')
        " matchseq treats spaces as part of the query, not unordered words.
        let l:result = matchfuzzypos(a:records, a:base, {'key': 'text', 'matchseq': 1})
        for l:index in range(len(l:result[0]))
            " Native results reference our records. Scores may be negative;
            " keeping a separate flag puts weak matches ahead of non-matches.
            let l:record = l:result[0][l:index]
            let l:record['matched'] = 1
            let l:record['score'] = l:result[2][l:index]
        endfor
        return
    endif

    let l:ignorecase = get(g:, 'lsp_ignorecase', &ignorecase)
    for l:record in a:records
        let l:text = l:record['text']
        if l:text ==# a:base
            let l:record['score'] = 3
        elseif stridx(l:text, a:base) == 0
            let l:record['score'] = 2
        elseif l:ignorecase && stridx(tolower(l:text), tolower(a:base)) == 0
            let l:record['score'] = 1
        endif
        let l:record['matched'] = l:record['score'] > 0
    endfor
endfunction
