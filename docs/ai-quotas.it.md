# Limiti del piano (Claude e Codex)

La pagina **Stato** dell'isola (il modulo *Uso AI*) mostra, per ogni fornitore, quanto è usato di ogni finestra del piano e il
tempo al suo azzeramento, accanto ai conteggi dei token di Claude Code. Un modulo compatto **Limiti AI** (solo le barre) si può
aggiungere a qualsiasi schermata in Impostazioni → Isola → Schermate.

## Claude (piani Pro e Max)

A ogni risposta Claude Code passa al suo programma di statusline un JSON che contiene `rate_limits.five_hour` e
`rate_limits.seven_day` (`used_percentage`, `resets_at`). È la fonte ufficiale e senza credenziali, e Cocaine legge solo quella:

- Attiva **Limiti del piano Claude** (Avvisi AI → Quando; spento di default, solo dall'app installata in Applicazioni). Cocaine
  imposta `statusLine.command` in `~/.claude/settings.json` a `'…/Cocaine' --statusline <il tuo comando precedente, base64> "$@"`.
- A ogni aggiornamento l'involucro conserva i limiti, il modello e la percentuale di contesto di quella sessione (nessun testo
  della conversazione, nessun percorso della trascrizione) in `~/Library/Application Support/Cocaine/claude-status/<sessione>.json`
  (0600; i record più vecchi di una settimana vengono cancellati), poi **esegue la tua statusline precedente con lo stesso input e
  gli stessi argomenti** e ne passa l'output e il codice di uscita. La tua statusline (ccstatusline e simili) continua a
  funzionare esattamente come prima.
- Spegnendolo torna esattamente il tuo comando precedente (o la statusline viene tolta se non c'era). Accenderlo due volte non
  cambia nulla; una statusline di altro tipo (non un comando) non viene toccata.
- I numeri compaiono dopo la prossima risposta di Claude Code, solo con i piani Pro/Max. Una finestra oltre l'orario di
  azzeramento senza notizie nuove è mostrata come azzerata, non con il numero vecchio.

## Codex

Codex scrive `rate_limits` nei suoi file di sessione (`~/.codex/sessions/**`). Ogni finestra prende il nome dalla sua durata
(`window_minutes`: 300 = 5 h, 10080 = Settimana, 1440 = Giorno, un mese = Mese): `primary` **non** è sempre la finestra di 5 ore
(con alcuni piani è quella settimanale e `secondary` è vuota). Accanto è mostrato il tipo di piano (`plan_type`). Come per
Claude Code, una finestra oltre l'orario di azzeramento senza file di sessione più recenti è mostrata come azzerata, non con il
numero vecchio.

## Cosa non viene fatto

Nessuna lettura del Portachiavi, nessun token OAuth, nessuna interrogazione di `/api/oauth/usage` (non documentata, limitata, e
richiederebbe le credenziali di Claude Code), nessuna API di quote di terzi (Kimi, GLM, DeepSeek, Grok…), nessun listino prezzi
scaricato. Tutto è locale.
