# Comandare Cocaine da script: AppleScript, Comandi Rapidi per Mac, link, riga di comando

Quattro modi con cui script, Comandi Rapidi, Keyboard Maestro, Raycast e simili possono comandare Cocaine. Tutto ciò che **cambia**
il comportamento del Mac (accendere, spegnere, alternare, mettere in pausa gli avvisi) è protetto allo stesso modo ovunque: funziona se
Generale → *App Comandi Rapidi e link* è attivo; altrimenti Cocaine te lo chiede una volta nella sua finestra (Non consentire è la
risposta predefinita; dopo un Non consentire le richieste sono rifiutate per 10 minuti, così nessuno può sommergerti di domande).
Leggere lo stato non è mai protetto. I valori sono controllati e limitati (1–1440 minuti, un'ora entro 24 ore); niente di tutto questo
legge o scrive file o avvia programmi.

## AppleScript (Cocaine.sdef)

```applescript
tell application "Cocaine"
    keep awake                         -- finché non lo fermi (senza timer)
    keep awake for 90                  -- minuti, da 1 a 1440
    keep awake until "18:30"           -- o "08:00 tomorrow", "2026-10-07T18:30", o una data entro 24 ore
    stop keeping awake
    toggle                             -- acceso con il timer del pannello, o spento
    get {awake, awake until, remaining minutes, screen off mode, trigger active}
end tell
```

- I comandi restituiscono se Cocaine ora è acceso (lo stato che sta applicando, non quello vecchio).
- `awake until` è `missing value` se non c'è timer o Cocaine è spento; `remaining minutes` allora è 0.
- Errori: un valore sbagliato è l'errore -1703 con un messaggio; un rifiuto (tuo, o durante i 10 minuti di rifiuto) è -1743.
- L'app che chiama (Script Editor, Comandi Rapidi, osascript nel Terminale…) ha bisogno del tuo consenso una volta in Privacy e
  sicurezza → Automazione: macOS lo chiede.
- In **Comandi Rapidi**: l'azione *Esegui AppleScript* (Comandi Rapidi → Impostazioni → Avanzate → *Consenti esecuzione script*).
  Anche JXA dovrebbe funzionare (non provato).
- Se Cocaine non è aperto, AppleScript lo avvia; aprire Cocaine lo accende, salvo diversa scelta in Generale → Tenere sveglio →
  *Accendi all'apertura di Cocaine*.

## Comandi rapidi per Mac (Automazioni → Comandi Rapidi e script → Aggiungi…)

Quattro comandi rapidi pronti, scelti uno alla volta: Cocaine lo crea, lo firma con `/usr/bin/shortcuts sign` (come quello per
iPhone: servono una connessione a Internet e iCloud) e lo apre in Comandi Rapidi, che ti chiede di aggiungerlo.

| Comando rapido | Cosa fa |
|---|---|
| Tieni sveglio… | chiede: *Finché non lo spengo* / *Per alcuni minuti…* (chiede un numero) / *Fino a un'ora…* (chiede un'ora) |
| Tieni sveglio: spegni | spegne |
| Tieni sveglio: alterna | accende o spegne |
| Tieni sveglio: stato | restituisce un **Dizionario**: `state` (on/off), `until` (ISO 8601 o vuoto), `remaining_minutes`, `screen_off_mode` (1/0), `trigger_active` (1/0) |

**In tutta onestà:** sono comandi rapidi normali, fatti con l'azione *Apri URL X-Callback* di Comandi Rapidi che chiama i link
`cocaine://` (la risposta torna come Dizionario). Non sono azioni native di Comandi Rapidi (App Intents) come "Set Enabled State" di
Lungo: quelle non possono funzionare per un'app senza una firma rilasciata da Apple ([maintainers/app-intents.md](maintainers/app-intents.md)).
Usali nei tuoi comandi rapidi (*Esegui comando rapido*), nelle automazioni di Comandi Rapidi (macOS 26+: ora del giorno, Full immersion,
rete Wi-Fi, Bluetooth, app aperta…: i trigger che Cocaine non ha), nella barra dei menu, in Spotlight o con Siri per nome. Alla prima
esecuzione compare una volta la domanda sui link (o attiva *App Comandi Rapidi e link*). *Non verificato qui*: eseguirli (vorrebbe dire
importarli in una libreria di Comandi Rapidi); la loro struttura è controllata su azioni e parametri noti di Comandi Rapidi da
`--awake-test`.

## Link

`cocaine://on`, `on?minutes=90`, `on?until=18:30`, `on?timer=off` (senza timer), `off`, `toggle`, `timer?minutes=…`,
`pause?minutes=…`, `resume`, `panel`, `status`; con `cocaine://x-callback-url/<comando>?x-success=…` Comandi Rapidi riceve lo stato.
Le risposte vanno solo all'indirizzo di risposta di Comandi Rapidi. Vedi [Alimentazione e trigger](power-and-triggers.it.md). Profili:
`profile?name=Ufficio&enabled=0|1`, AppleScript `enable profile` / `disable profile` / `active profile` / `profile names`, e
`cocaine profiles` / `cocaine disks` ([Profili per tenere sveglio il Mac](awake-profiles.it.md)).

## Riga di comando

Il motore dentro l'app (`/Applications/Cocaine.app/Contents/Resources/cocaine`): `cocaine on`, `on 90m`, `on until 18:30`,
`on until 08:00 tomorrow`, `off`, `status --json`, `mode screen-off|normal`. Non chiede permessi (sei tu, in un terminale).

**"Accendi" senza durata, ovunque** (verificato sul codice nella revisione del giro 7):

| Modo | Senza durata significa |
|---|---|
| AppleScript `keep awake` | finché non lo spegni (nessun timer) |
| Link `cocaine://on` | il timer del pannello (Generali → *Tieni sveglio per*); `on?timer=off` per nessuno |
| `toggle` (link, AppleScript, comando rapido) | acceso con il timer del pannello, oppure spento |
| Riga di comando `cocaine on` | una scadenza già impostata resta; altrimenti nessuna |
| iPhone / `cocaine remote on` | finché non lo spegni (una scadenza già impostata viene tolta) |

`off` da uno qualsiasi di questi chiude ogni scadenza.

## Prove (per chi sviluppa)

- `Cocaine --awake-test`: le regole, il dizionario come Cocoa lo carica dal bundle, i comandi eseguiti su un'app finta (decide il
  controllo dei permessi, errori, risultati), la struttura dei comandi rapidi.
- `Cocaine --scripting-selftest`: AppleScript vero, compilato con il dizionario e inviato alla copia stessa (stato finto).
- `Cocaine --scripting-serve 60`: una copia che risponde ad Apple Event veri di altri processi su uno stato in memoria, non avvia nulla
  di Cocaine e non prende mai il posto del Cocaine aperto; avviala da una copia con un bundle id suo (come fa verify.sh) e parlale con
  `osascript -e 'tell application id "<quell'id>" to keep awake for 30'`. La prima volta macOS chiede se il Terminale può controllarla.
