<p align="center"><img src="docs/icona.png" width="128" alt="Icona di Cocaine"></p>

<h1 align="center">Cocaine</h1>

<p align="center"><b>Tiene sveglio il Mac, anche col coperchio chiuso.</b><br>
Una piccola app gratuita e open source per la barra dei menu di macOS.</p>

<p align="center"><img src="docs/demo.gif" width="360" alt="La bustina nella barra dei menu si riempie quando Cocaine si attiva"></p>

🇬🇧 [Read in English](README.md)

- **Bustina piena = attivo.** Il Mac non va in stop, nemmeno col coperchio chiuso. Funziona anche su Apple Silicon,
  senza componenti aggiuntivi da installare.
- **Bustina vuota = spento.** Il Mac si comporta normalmente.
- **Un interruttore.** Quello in alto nel pannello attiva o spegne Cocaine; mentre si accende ci scende dentro una
  sottile striscia di polvere.
- **Parla la tua lingua:** italiano, inglese, cinese (semplificato e tradizionale), spagnolo, francese, tedesco e giapponese.
  Segue la lingua del Mac (altrimenti l'inglese), oppure la scegli dalla bandiera nel pannello.
- **Luminosità.** Mentre è attivo, può abbassare lo schermo integrato al livello che scegli dopo qualche minuto di
  inattività. Lo schermo non si spegne mai del tutto, e torna com'era appena tocchi tastiera o trackpad.
- **Anche con monitor esterni.** I monitor Apple abbassano la retroilluminazione, gli altri si scuriscono via software, e col
  coperchio chiuso si abbassano solo gli schermi esterni. Il pannello si apre sotto l'icona che clicchi, su qualunque schermo.

<p align="center"><img src="docs/pannello.png" width="340" alt="Il pannello di Cocaine"></p>

Richiede macOS 14 (Sonoma) o successivo. Funziona su Mac Apple Silicon e Intel, pesa circa 600 KB, è gratis.

## Installazione

**Con Homebrew (il modo più semplice):**

```
brew install --cask mattiakart/tap/cocaine
```

Homebrew ti chiede la password del Mac **una volta**, direttamente nel Terminale, per dare il permesso a Cocaine. Se hai attivato
Touch ID per sudo, basta l'impronta. Nient'altro: nessuna finestra, niente "Apri comunque".
`brew upgrade` non chiede mai nulla, e `brew uninstall --cask cocaine` toglie tutto senza chiedere.

**Oppure scarica il .dmg** dalla pagina [Releases](../../releases/latest):

1. Apri il `.dmg` e trascina **Cocaine** in **Applicazioni**.
2. Aprila. macOS la blocca, perché l'app non è firmata da uno sviluppatore registrato presso Apple:
   vai in **Impostazioni di Sistema → Privacy e sicurezza** e clicca **"Apri comunque"**. Serve solo la prima volta.
3. Cocaine chiede **una volta** la password. macOS la mostra con un avviso perché l'app non è verificata da Apple: è normale.

In entrambi i casi quell'autorizzazione installa una regola sudo che permette solo `pmset -a disablesleep 1`,
`pmset -a disablesleep 0` e la cancellazione della regola stessa (più `pmset schedule wake`/`cancel wake`, marcati `cocaine`,
se attivi *Sveglia per iPhone*). Nient'altro.

**Firma.** Le versioni attuali sono firmate con un certificato autofirmato di Cocaine (livello "locale"): gratuito, ma non
verificato da Apple e non notarizzato, da qui "Apri comunque". Il pannello mostra il livello della tua copia in *Permessi*. macOS
conserva i permessi concessi negli aggiornamenti firmati con lo stesso certificato, ma Apple non promette nulla per i
certificati autofirmati: se dopo un aggiornamento un interruttore risulta spento, riaccendilo una volta. La firma Developer ID e
la notarizzazione sono previste dagli script di build ma non ancora usate dalle versioni pubblicate. Gli **aggiornamenti
nell'app** (pannello → Aggiornamenti) verificano un manifest firmato Ed25519, l'hash del DMG e la firma della nuova app prima di
una sostituzione atomica, ma restano inattivi finché una versione non include un manifest firmato e la sua chiave pubblica non è
incorporata nell'app: fino ad allora usa `brew upgrade --cask cocaine` o il DMG. Le installazioni Homebrew non vengono mai
sostituite dall'app. Dettagli: [Firma e aggiornamenti](docs/signing-and-updates.it.md).

## Avvisi quando un'AI finisce

Lasci il Mac a lavorare, e Cocaine ti richiama quando un'AI finisce o ha bisogno di te. Se non sei al Mac riaccende gli
schermi, riporta la luminosità, li fa lampeggiare e mostra chi ti cerca e in quale progetto. Se sei al Mac, la bustina
nella barra si ricarica e basta.

Apri **Avvisi AI** nel pannello. I suoi quattro gruppi mostrano un riassunto in una riga e si aprono uno alla volta:
**AI collegate** (un interruttore per ciascuna, con cosa segnala), **Quando** (finisce, ha bisogno di te, anche quando
sei al Mac, oppure una volta sola per sessione, quando non resta niente in corso, invece che per ogni agent o task che finisce; e
**Rispondi dal notch**, spento di default), **Come** (lampeggio, suono, voce e quale, quanto resta l'avviso sullo schermo, promemoria ogni 2, 5 o 10 minuti
mentre sei via, e una prova) e **Pausa** (30 minuti, un'ora o fino a domani). Sotto, separati dalle impostazioni,
gli **Ultimi avvisi**, con il progetto da cui arrivano.

**Ogni sessione, nel notch.** La pagina Home dell'isola e il pannello elencano tutte le tue sessioni AI (con scorrimento quando
sono tante; fino a 100), prima quelle che hanno bisogno di te. L'elenco viene salvato e ricompare dopo un riavvio (con ↺ e l'età);
una sessione il cui processo è terminato viene tolta. **Clicca una sessione o un avviso** per tornare dove gira: la scheda esatta
di Terminale o iTerm2 (serve il permesso *Automazione* per quell'app, chiesto la prima volta), il pannello tmux o WezTerm, o la
finestra di VS Code, Cursor o Windsurf con la sua cartella; se non riesce ad arrivare fin lì porta avanti l'app o apre la cartella,
e dice sempre cosa ha fatto. Il terminale integrato di un IDE, JetBrains, Ghostty, kitty e Warp si possono solo portare in primo
piano come app, e le sessioni avviate prima di questa versione non dicono dove girano.

**Consenti o nega dal notch** (spento di default; Claude Code 2.0.45+ e Codex): le richieste di permesso, e le domande MCP di
Claude Code con risposte semplici, compaiono con **Consenti** / **Nega** / **Nel terminale**. Usa solo gli hook documentati degli
strumenti (`PermissionRequest`, `Elicitation`) su un socket privato, con risposte firmate e legate a una sola richiesta. Niente
viene mai approvato da solo: nessuna risposta entro 2 minuti, Cocaine non in esecuzione o qualsiasi errore, e lo strumento chiede
nel terminale come sempre. L'`AskUserQuestion` di Claude Code non ha un hook per le risposte, quindi viene solo annunciata. Gli
altri strumenti della tabella avvisano soltanto. Dettagli: [Sessioni AI](docs/ai-sessions.it.md).

| AI | Finisce | Ha bisogno di te | Dove va l'hook di Cocaine |
|---|---|---|---|
| Claude Code | ✓ | ✓ permesso o domanda | `~/.claude/settings.json` |
| Codex (CLI e app ChatGPT) | ✓ | ✓ approvazione | `~/.codex/hooks.json` |
| Cursor | ✓ | – | `~/.cursor/hooks.json` |
| GitHub Copilot (CLI e VS Code) | ✓ | ✓ nella CLI | `~/.copilot/hooks/cocaine.json` |
| Gemini CLI | ✓ | ✓ permesso | `~/.gemini/settings.json` |
| Windsurf | ✓ dopo ogni risposta | – | `~/.codeium/windsurf/hooks.json` |
| Qwen Code | ✓ | ✓ permesso | `~/.qwen/settings.json` |
| OpenCode | ✓ | ✓ permesso o domanda | `~/.config/opencode/plugins/cocaine.js` |

Cocaine aggiunge solo i suoi hook e lascia com'è tutto il resto di quei file. Togliendo la spunta a un'AI li rimuove, e
lo fa anche `brew uninstall`. Codex esegue un hook nuovo solo dopo che l'hai approvato una volta (te lo chiede all'avvio
nel Terminale, oppure nell'app ChatGPT vai in Impostazioni → Hooks): finché non lo fai, il pannello te lo ricorda.
Cursor esegue anche gli hook di Claude Code, quindi quello di Cocaine per Claude Code dentro Cursor tace: niente avvisi
doppi.

**Qualsiasi altro programma** può suonare il "campanello":

```
open -g "cocaine://alert?from=Il%20mio%20script&event=done"     # event=done o input; project=nome; oppure message=testo
```

- **Altre AI** con hook o plugin che possono eseguire quel comando: Aider (`notifications-command` in
  `~/.aider.conf.yml`), Cline (`~/Documents/Cline/Hooks/TaskComplete`), Factory Droid (`~/.factory/hooks.json`), Kiro,
  Amp, Goose, JetBrains Junie (non sull'hook `PermissionRequest`: se esce senza decidere, Junie approva l'azione).
- **Build e terminali:** Xcode (Impostazioni → Behaviors → Run script), qualsiasi comando lungo (`make; open -g …`),
  `notify_on_cmd_finish` di kitty, i Trigger di iTerm2, `alert-silence` di tmux.
- **CI e git:** `gh run watch --exit-status; open -g …`, hook di git come `post-merge`.
- **App di automazione:** Comandi Rapidi ("Apri URL"), Keyboard Maestro, Hammerspoon, BetterTouchTool, `WatchPaths` di
  launchd, regole di Mail.

Gli hook di Cocaine iniziano con `pgrep -qx Cocaine`: l'avviso parte solo se Cocaine è aperto, e non lo riapre se l'hai
chiuso.

## Feedback e assistenza

La ✉︎ accanto alla versione, nel pannello, apre una mail all'autore con le versioni di Cocaine e di macOS già scritte.
Bug e idee sono benvenuti anche come [issue su GitHub](https://github.com/Mattiakart/cocaine/issues).

## Isola

Cocaine vive anche nel notch (o, su uno schermo senza, in una sottile pillola in alto). Chiusa, mostra accanto al notch ciò che
è attivo: Cocaine acceso e fino a quando, il conto alla rovescia del focus, un'AI che aspetta te, il microfono in uso, il
brano in riproduzione e brevi messaggi ("Scaricato", "Screenshot", "Copiato", le barre di volume e luminosità). Ci passi sopra
o ci clicchi e si apre, con queste pagine:

- **Home**: l'interruttore, il timer, gli agent AI al lavoro.
- **Musica**: Musica e Spotify, con copertina, barra di avanzamento, play/pausa/avanti/indietro/casuale e, se li attivi, i
  testi sincronizzati (cercati per titolo e artista su lrclib.net, non si invia altro). Serve il permesso Automazione.
- **Calendario**: oggi e i prossimi eventi, fino a due settimane (chiede l'accesso a Calendario quando premi il pulsante).
- **Focus**: un timer focus/pausa con righello dei minuti; avviare un focus tiene il Mac sveglio.
- **Scaffale**: trascina dei file sull'isola (si apre da sola) e tienili lì, poi trascinali fuori o mandali tutti con AirDrop.
- **File**: download e screenshot recenti, da trascinare fuori (in qualsiasi app, Mail, AirDrop…); un lampo avvisa quando ne arriva uno.
- **Appunti**: ciò che hai copiato da poco (testo, immagini, riferimenti a file), con ricerca e preferiti; clicca per copiare di nuovo.
  Solo in memoria, a meno che attivi *Salva su questo Mac* (cifrato, con limiti di conservazione, esclusioni e *Elimina tutto*);
  mai dai gestori di password. [Dettagli e limiti](docs/clipboard.it.md).
- **Stato**: le batterie del Mac, degli AirPods e di altri dispositivi Bluetooth, e l'utilizzo di Codex (i limiti) e Claude Code (i token), letti dai loro file locali.
- **Multimedia**: Apple Music, Spotify, YouTube Music, Netflix, Prime Video, YouTube, Disney+, Apple TV, Twitch, DAZN: un tocco apre l'app se
  è installata, altrimenti il sito nel browser predefinito.
- **Specchio**: la fotocamera dal vivo, accesa solo mentre quella pagina è aperta; un interruttore la specchia (o ti mostra come ti vedono gli
  altri) e puoi scegliere la fotocamera.
- **Monitor** (solo con un monitor esterno): luminosità, contrasto, volume e ingresso del monitor stesso via DDC/CI, solo Apple
  silicon; non tutti i monitor lo supportano e non si possono rileggere i valori.

Anche il caricatore collegato o scollegato viene annunciato. L'isola sostituisce l'icona nella barra dei menu: la busta di Cocaine, sempre a sinistra, si riempie e si svuota come faceva l'icona (polvere
bianca: Cocaine è attivo; polvere rosa: Cocaine è spento ma *Resta attivo* è acceso, con o senza app di chat aperte). Se disattivi l'isola, l'icona torna. Si apre e si chiude
seguendo le linee del notch, con un leggero tocco sul trackpad dove serve (timer, interruttori, pagine; *Cocaine → Feedback aptico* lo disattiva). L'ingranaggio apre il pannello delle impostazioni; *Cocaine → Isola* la disattiva. Si nasconde durante video a schermo intero e
giochi. Con *Cocaine →
Sostituisci l'HUD di sistema* attivo, volume e luminosità compaiono solo nell'isola: l'HUD di macOS viene zittito (il suo processo di supporto resta
congelato) e torna appena disattivi l'opzione o chiudi Cocaine; se Cocaine va in crash o viene terminato, un piccolo watchdog lo
restituisce in un paio di secondi ([dettagli](docs/recovery.it.md)). Zittirlo non richiede permessi, ma perché Cocaine gestisca da
sé i *tasti* di volume e luminosità (passi fini con ⌥⇧) serve il permesso **Accessibilità**, che chiede quando attivi l'opzione.
Senza, macOS cambia comunque volume e luminosità e l'isola li mostra.

## Lavoro da remoto

Lasci il Mac e continui a lavorare dal telefono. Cocaine tiene sveglio il Mac (il coperchio può restare chiuso) e un
piccolo comando ti permette di avviare, seguire e guidare gli agent AI da qualsiasi posto in cui puoi eseguire un comando.

**Da fare una volta, da qualsiasi parte del mondo, senza password e senza altre app.** Cocaine non apre nessuna porta di
rete e non richiede né il Login remoto né una VPN. L'app tiene una connessione in uscita verso un relay ([ntfy](https://ntfy.sh),
lo stesso servizio che possono usare gli avvisi sul telefono) e il Comando Rapido dell'iPhone parla con l'app attraverso di esso.

1. Nel pannello: *Lavoro da remoto → iPhone → Invia*. Scegli cosa può fare il telefono e Cocaine crea un Comando
   Rapido (un menu: Stato, Attiva, Spegni, Progetti, Comando, Ultima risposta), lo firma (servono internet e iCloud sul Mac)
   e apre la condivisione: lo mandi con AirDrop o con Messaggi.
2. Sull'iPhone lo aggiungi e lo esegui. Basta: il segreto che contiene il Mac lo conosce già.

*Comando* accetta qualsiasi comando `cocaine remote`, per esempio `start claude mio-progetto Correggi i test che falliscono`,
`log claude-mio-progetto 30`, `send claude-mio-progetto Sì, procedi` (gli ultimi tre richiedono il livello agent). Il Comando
Rapido aspetta qualche secondo e mostra la risposta; *Ultima risposta* la mostra di nuovo.

Come è protetto: ogni iPhone abbinato riceve due nomi di canale casuali sul relay e una propria chiave casuale da 256 bit. Comandi
e risposte sono **autenticati e cifrati end-to-end** con essa, quindi il relay vede solo testo cifrato (non il comando, lo stato,
i nomi dei progetti o l'output degli agent); un comando senza la chiave giusta viene ignorato e una risposta è legata alla
richiesta a cui risponde. **I replay sono rifiutati per sempre**: ciò che il Mac ha eseguito viene salvato su disco prima
dell'esecuzione, quindi i duplicati consegnati di nuovo dopo una riconnessione, un risveglio o un riavvio vengono scartati, e i
comandi più vecchi di due minuti (20 con *Sveglia per iPhone*) o datati nel futuro sono rifiutati. *Revoca* dimentica subito tutti
gli iPhone abbinati (un comando già in corso non riceve risposta); un abbinamento scade dopo 180 giorni. Ogni comando passa da
una lista fissa di comandi permessi: il livello di base permette stato, attiva/spegni ed elenco dei progetti; *Anche avviare e
guidare gli agenti AI* aggiunge l'avvio degli agent e la possibilità di scrivere loro, il che equivale a eseguire codice come te:
concedilo consapevolmente. Al massimo 20 comandi al minuto e ognuno è registrato in
`~/Library/Application Support/Cocaine/remote-phone.log`. Trattalo come una chiave: il Comando Rapido contiene la chiave, si
sincronizza tramite iCloud come ogni Comando Rapido e chiunque lo ottenga può usarlo.

**I Comandi Rapidi creati prima di questa versione** (testo in chiaro, non autenticati) vengono rifiutati dopo l'aggiornamento; il
pannello mostra una riga arancione *Comandi Rapidi vecchi*: manda un nuovo Comando Rapido e poi *Rimuovi*, oppure *Consenti 14
giorni* per far eseguire intanto quelli vecchi solo i comandi di base (mai avviare agent), senza protezione.

Limiti, onestamente: l'app Comandi Rapidi non ha un'azione di cifratura, quindi il Comando Rapido la fa con hash ed espressioni
regolari (costruzioni standard, verificate col codice del Mac). È grande (circa 650 azioni), un comando richiede qualche secondo
sull'iPhone e le risposte oltre circa 2.800 byte vengono tagliate. Il relay vede ancora quando e quanto spesso mandi comandi e può
ritardarli o scartarli. Un comando su cui il Mac va in crash subito dopo averlo accettato non viene eseguito (mai due volte).
**Il nuovo Comando Rapido è stato verificato in un simulatore delle sue azioni, non ancora su un iPhone reale.** Il Mac deve essere
sveglio per rispondere: a questo serve Cocaine acceso. Per evitare un relay di terzi usa un tuo server ntfy:
`defaults write local.cocaine.toggle relayURL https://ntfy.esempio.it` (solo https), poi abbina di nuovo. Descrizione completa:
[Sicurezza del controllo remoto](docs/remote-security.it.md).

Gli stessi comandi funzionano in Terminale:

```
C=/Applications/Cocaine.app/Contents/Resources/cocaine
$C remote status                       # Cocaine, batteria, agent al lavoro
$C remote on --for 3h                  # Mac sveglio per 3 ore
$C remote projects                     # le cartelle in cui puoi lavorare
$C remote start claude mio-progetto Correggi i test che falliscono
$C remote start codex mio-progetto --resume
$C remote log claude-mio-progetto 30    # cosa mostra l'agent sullo schermo
$C remote send claude-mio-progetto Sì, procedi
$C remote key claude-mio-progetto enter # anche esc, up, down, tab, ctrl-c, y, n, 1-9
$C remote stop claude-mio-progetto
```

Agent: Claude Code, Codex, Gemini CLI, Cursor, GitHub Copilot, OpenCode, Qwen Code e Aider (`remote agents` elenca quelli
installati; `--resume` riprende l'ultima conversazione per Claude Code, Codex, Cursor, Copilot e OpenCode). Ognuno gira
in una sessione `screen` che sopravvive alla chiusura della connessione (`remote attach <run>` la riprende in un
terminale). I progetti sono le cartelle con un `.git` sotto `~/Developer`, `~/Projects`, `~/Documents` e `~/Desktop`
(la lista si cambia in `~/Library/Application Support/Cocaine/projects.conf`). Cocaine si attiva quando parte il lavoro
e torna com'era quando finisce l'ultimo.

**Sapere cosa succede.** Gli hook degli Avvisi AI dicono a Cocaine anche quando un agent inizia a lavorare, aspetta te,
finisce o va in errore, e il pannello li elenca. `remote status` mostra lo stesso, e gli **Avvisi sul telefono** ti
mandano ogni avviso: con `cocaine remote notify shortcut "Nome"` Cocaine esegue quel Comando Rapido (con il testo
dell'avviso come input: costruiscine uno che ti manda un messaggio o una notifica), oppure con
`cocaine remote notify ntfy https://ntfy.sh/il-tuo-argomento-segreto` ricevi una notifica push (il testo dell'avviso
passa da quel servizio). `cocaine remote notify test` lo prova.

**Svegliare il Mac.** È Cocaine attivo a tenerlo raggiungibile. Un Mac già andato in stop non sente il relay, e niente da
internet può svegliare un MacBook in stop con il coperchio chiuso. Quindi, in *Lavoro da remoto*, attiva **Sveglia per
iPhone**: Cocaine programma un breve risveglio ogni 15 minuti (anche con il coperchio chiuso). A ogni risveglio si
ricollega, esegue i comandi che l'iPhone ha mandato nel frattempo (fino a 20 minuti di età), risponde e lascia che il Mac
torni a dormire. Quindi un comando mandato a un Mac in stop riceve risposta entro circa 15 minuti: lo mandi e dopo usi
*Ultima risposta*. Chiede il permesso una volta (estende la regola sudo di Cocaine con `pmset schedule wake`/`cancel wake`,
marcati `cocaine`, nient'altro), consuma un po' di batteria, si ferma a batteria al 20% o meno e viene annullata quando
chiudi Cocaine. Se serve la risposta subito, tieni Cocaine attivo. (`cocaine remote wake-info` stampa ancora quello che serve
a un'app Wake-on-LAN, da usare sulla rete di casa.)

**Anche dai Comandi Rapidi e dagli script sul Mac.** Cocaine non ha azioni native per i Comandi Rapidi: richiedono metadati che
produce solo la toolchain di Xcode, mentre l'app è compilata con i Command Line Tools. Al loro posto: i link (`cocaine://on?minutes=90`,
`off`, `toggle`, `timer`, `status` con risposta x-callback; anche `pause`, `resume`, `panel`) e il comando incluso (`cocaine on 90m`,
`off`, `status --json`, usabile da *Esegui script shell*). I link che cambiano qualcosa funzionano solo dopo il tuo consenso (una
domanda la prima volta, oppure Automazioni → Scorciatoie → *App Comandi Rapidi e link*), perché qualsiasi app o pagina web può
aprire un link. Vedi [Alimentazione e trigger](docs/power-and-triggers.it.md).

### Automazioni

**Resta attivo** (scheda Automazioni): Teams, Slack, Zoom e app simili ti segnano "Assente" in base all'inattività del Mac. Mentre
sei inattivo, con una delle app scelte aperta (o sempre), Cocaine invia ogni tanto un evento di mouse invisibile, che riavvia
quell'orologio, e tiene lo schermo acceso. Serve il permesso Accessibilità; verifica che nel tuo lavoro sia consentito.

Il pannello ha tre schede: *Generale* (il **Timer** subito sotto l'interruttore: ∞, da 30 minuti a 8 ore, o qualsiasi durata a passi di 15 minuti fino a 24 ore, poi si spegne; più luminosità e agent al lavoro), *Avvisi AI* e *Automazioni*: **Battery Guard** (a batteria,
al 10–30 % spegne Cocaine o ti avvisa soltanto), **Smart Triggers** (attivo mentre un'AI lavora o aspetta te, mentre girano i
programmi scelti, con il caricatore o a batteria, con un monitor esterno collegato o no, o in una fascia oraria settimanale; vale
"uno qualsiasi" o "tutti"; si spegne dopo un breve periodo di tolleranza; se lo spegni tu a mano, vale la tua scelta) e
**Scorciatoie** (⌃⌥⌘C attiva/spegne, ⌃⌥⌘O pannello, ⌃⌥⌘P pausa avvisi).

**Schermo spento, Mac sveglio** (Generale → luminosità → *Spegni lo schermo invece*): dopo il tempo di inattività gli schermi si
spengono del tutto mentre il Mac continua a lavorare. Niente viene aggirato: il blocco segue *Impostazioni di Sistema → Schermata
di blocco* (in questa modalità lo schermo non è più tenuto acceso, quindi macOS può spegnerlo anche prima). Con il coperchio
chiuso e a batteria, se macOS segnala uno stato termico serio, Cocaine si spegne da solo. *Resta attivo* si ferma mentre gli
schermi sono spenti, gli schermi AirPlay/Sidecar/DisplayLink possono ignorare lo spegnimento, e il comportamento con monitor
esterno e coperchio chiuso è documentato ma non è stato provato su hardware reale. Vedi
[Alimentazione e trigger](docs/power-and-triggers.it.md).

## Da sapere

- Mentre Cocaine è attivo il Mac **non si blocca da solo**, anche col coperchio chiuso: bloccalo con ⌃⌘Q.
- A batteria e col coperchio chiuso il Mac continua a consumare, e non va in stop nemmeno con la batteria quasi scarica.
- Quando apri l'app, Cocaine si attiva, e quando la chiudi rimette le cose com'erano. Vale per **Esci**, ⌘Q, la disconnessione, lo
  spegnimento, `kill` e i crash (un piccolo watchdog si accorge che Cocaine non c'è più). Se lo stop era già disattivato prima che
  Cocaine lo attivasse, o lo hai cambiato nel frattempo, viene rispettato. Limiti: dopo un'interruzione di corrente o un riavvio
  forzato lo stop resta disattivato finché Cocaine non si riapre (o esegui `cocaine off`), e se Cocaine e il suo watchdog vengono
  terminati insieme nessuno può intervenire fino al prossimo avvio. [Dettagli](docs/recovery.it.md).
- Domande, messaggi ed elenco di condivisione compaiono dentro il pannello o l'isola di Cocaine, con lo stesso design. Ciò che
  appartiene a macOS resta di macOS: la richiesta della password di amministratore, le domande sui permessi di privacy, le
  Impostazioni di Sistema e le finestre che AirDrop, Messaggi e Mail aprono dopo la scelta (Apple non permette di incorporarle).
- Gira una sola copia di Cocaine alla volta: una seconda copia aperta mentre un'altra è in esecuzione si fa da parte.

## Disinstallazione

Con Homebrew: `brew uninstall --cask cocaine`. Spegne Cocaine e toglie l'app, la regola sudo e gli hook degli Avvisi AI,
senza chiedere nulla. (`--zap` cancella anche le impostazioni, la cronologia degli appunti e gli altri dati salvati.) Le modifiche al
cask che fanno rispettare del tutto le regole di ripristino in disinstallazione e aggiornamento arrivano con la prossima versione:
[note](docs/maintainers/cask-changes.md).

Senza Homebrew: togli le spunte in Avvisi AI, esci da Cocaine (così si spegne), spostala nel Cestino, poi nel Terminale:

```
sudo rm /etc/sudoers.d/cocaine
```

## Come funziona

- `pmset -a disablesleep 1` impedisce lo stop, anche a coperchio chiuso. L'app installa una regola sudo che
  permette senza password **solo** i due comandi `pmset -a disablesleep 1` e `pmset -a disablesleep 0`.
- Mentre è attivo, `caffeinate -d` tiene acceso lo schermo (`-i` nella modalità schermo spento).
- La luminosità è gestita con le API DisplayServices di macOS.

Codice: `main.swift` e [`Sources/`](Sources) (app per la barra dei menu, Swift/SwiftUI) e `cocaine.zsh` (lo script "motore").
Per compilare: `./build.sh --dmg` (`--sign local|developer-id|adhoc` sceglie il livello di firma e non ripiega mai su un altro;
`--release` rifiuta ad hoc). `./verify.sh` compila ed esegue tutti i controlli automatici; lo stesso gira su GitHub Actions.

## Licenza

MIT: vedi [LICENSE](LICENSE).
