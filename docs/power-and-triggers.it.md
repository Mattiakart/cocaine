### Schermo spento, Mac sveglio

Generale → *Quando sei inattivo* → **Spegni**: con Cocaine attivo, dopo il tempo di inattività
scelto gli schermi (integrato ed esterni) si spengono invece di abbassarsi (`pmset displaysleepnow`, senza password di
amministratore). Il Mac continua a lavorare: download, compilazioni e agenti AI vanno avanti. **Spegni ora** (nella stessa scheda) li spegne subito. Un
tasto, un clic o un tocco sul trackpad li riaccende.

- **Blocco:** nulla viene aggirato. Quando gli schermi si spengono macOS si blocca come impostato in *Impostazioni di
  Sistema → Blocco schermo* ("Richiedi la password dopo l'avvio del salvaschermo o lo spegnimento del monitor"). In questa
  modalità il motore di Cocaine non tiene più acceso lo schermo (`caffeinate -i` invece di `-d`), quindi vale anche il timer di
  spegnimento dello schermo di macOS, che può spegnerlo prima. In modalità normale lo schermo resta acceso e macOS non si
  blocca per inattività (come prima).
- **Coperchio:** a coperchio chiuso senza monitor esterno lo schermo integrato è già spento; il Mac resta sveglio come sempre
  con Cocaine attivo. Coperchio chiuso con monitor esterno: il monitor esterno si spegne come gli altri.
- **Calore e batteria:** a coperchio chiuso, a batteria, se macOS segnala uno stato termico *serio* o *critico* (Mac in
  borsa), Cocaine si disattiva per lasciare dormire il Mac e te lo dice. La Protezione batteria funziona come prima e impedisce
  anche all'Attivazione automatica di riattivare Cocaine finché la batteria non si riprende o non colleghi il caricatore.
- **Resta disponibile:** in questa modalità non tiene più acceso lo schermo e non manda mai il suo evento di mouse invisibile a uno
  schermo spento (lo riaccenderebbe), quindi le app di chat possono mostrarti assente a schermi spenti. Abbassamento e
  spegnimento contano dall'ultimo input reale, ignorando gli eventi di Resta disponibile (prima, con Resta disponibile acceso, un
  abbassamento dopo 1 minuto non scattava mai).
- **Avvisi** (Avvisi AI con *Lampeggio*) riaccendono comunque gli schermi, di proposito.
- **Limiti:** schermi AirPlay, Sidecar e alcuni DisplayLink possono non rispettare lo spegnimento. Alcuni monitor mostrano
  "nessun segnale" prima di andare in standby.

### Attivazione automatica: alimentazione, monitor esterno, orari

Automazioni → Attivazione automatica, accanto a *Un'AI è al lavoro* e *Questi programmi sono aperti*:

- **Alimentazione:** *In carica*, oppure *A batteria* finché la carica è sopra il livello della Protezione batteria (10 % se è spenta: un solo livello per entrambe). Un Mac senza batteria
  conta come in carica.
- **Monitor esterno:** *Connesso* o *Non collegato* (contano anche i monitor in stop; AirPlay/Sidecar contano come esterni).
- **Orari:** giorni della settimana e ora di inizio/fine sull'orologio locale. Una fine uguale o precedente all'inizio passa la
  mezzanotte e appartiene al giorno in cui inizia (ven 22:00–06:00 comprende sabato alle 02:00). Segue ora legale e cambi di
  fuso; la notte in cui l'ora torna indietro una fascia dentro l'ora ripetuta dura quell'ora in più.
- **Attiva quando:** *Ne vale almeno uno* (basta un motivo, predefinito) o *Valgono tutti* (compare da due trigger attivi).

Cocaine si attiva quando i trigger lo chiedono e si disattiva dopo un margine: 3 minuti per AI e programmi, 30 secondi per
alimentazione e monitor (un cavo che balla non lo fa scattare), nessuno per gli orari. Precedenza: se lo disattivi tu
(interruttore, scorciatoia, `cocaine://off`, `cocaine off`, `cocaine remote off`, il timer o la Protezione batteria) la scelta vale
finché i trigger non cessano; se lo attivi tu, nessun trigger lo spegne. I trigger sono controllati ogni 5 secondi e subito
dopo un risveglio, un cambio di ora o di fuso, o un cambio di monitor.

### Comandi Rapidi e script

L'app è compilata con i soli Command Line Tools (`swiftc`). Le azioni native di Comandi Rapidi (App Intents) richiedono i
metadati che `appintentsmetadataprocessor` di Xcode genera in compilazione; quello strumento non fa parte dei Command Line
Tools e senza di esso Comandi Rapidi non mostra le azioni. Cocaine offre quindi due vie supportate:

**Link** (Comandi Rapidi → *Apri URL*, o *Apri URL X-Callback* per ricevere una risposta):

| Link | Fa |
|---|---|
| `cocaine://on` · `cocaine://on?minutes=90` | attiva (per 1–1440 minuti) |
| `cocaine://off` · `cocaine://toggle` | disattiva · inverte |
| `cocaine://timer?minutes=90` | attiva per quel tempo |
| `cocaine://status` | niente; con x-callback, la risposta |
| `cocaine://x-callback-url/status?x-success=…` | risponde `state` (on/off), `until` (ISO 8601), `remaining_minutes`, `screen_off_mode`, `trigger_active` |

Qualsiasi app o pagina web può aprire un link, quindi i link che cambiano qualcosa funzionano solo dopo il tuo consenso: la
prima volta Cocaine chiede (*Consenti* / *Non consentire*; dopo *Non consentire* i link vengono ignorati per 10 minuti), oppure
attiva Generale → **App Comandi Rapidi e link**. Le risposte vanno solo a callback `shortcuts://`. Valori
errati (`minutes=0`, `abc`, oltre 1440) sono rifiutati, non indovinati. Un link che avvia Cocaine non lo attiva da sé prima;
`status` da solo lo avvia, risponde ed esce.

**Esegui script shell** (il motore dentro l'app; gira come te, l'app non serve):

```sh
C=/Applications/Cocaine.app/Contents/Resources/cocaine   # o ~/Applications/…
$C on            # attiva (mantiene un eventuale timer)
$C on 90m        # attiva per 90 minuti (90, 2h, 1h30m; da 1 min a 24 h); poi lo spegne Cocaine.app
$C off
$C status --json # {"state":"ON","on":true,"until":1790000000,"remaining_minutes":42,"screen":"kept on","screen_off_mode":false}
```

Usa *Ottieni dizionario dall'input* sul JSON. Attivare/disattivare così conta come scelta tua per gli Smart Trigger. Lo
spegnimento a tempo richiede che Cocaine.app sia in esecuzione.
