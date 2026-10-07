### Niente sopravvive a Cocaine

Aprire Cocaine lo accende; chiuderlo rimette le cose come stavano. Vale anche quando Cocaine non si chiude normalmente:

- **Stop.** Cocaine ricorda se lo stop era già disattivato *prima* che lo disattivasse lui (da te, con `pmset`, o da
  un'altra app). Quando ha finito — Esci, logout, `kill`, Ctrl-C, un crash o `kill -9` — lo stop torna com'era prima,
  a meno che nel frattempo qualcuno l'abbia cambiato (allora resta quella modifica). Spegnere Cocaine con il suo
  interruttore, dall'iPhone o con `cocaine off` resta uno spegnimento esplicito. L'helper che tiene acceso lo schermo si
  chiude insieme a lui. Comandi dati nello stesso istante dall'app, dall'iPhone e dal Terminale non si intralciano.
- **Indicatori di sistema.** Con *Sostituisci HUD di sistema* attivo, l'indicatore di volume/luminosità di macOS resta
  congelato finché Cocaine è aperto. Se Cocaine va in crash o viene terminato, l'indicatore torna entro un paio di secondi;
  se Cocaine si blocca, dopo 30 secondi. Viene toccato solo l'indicatore congelato da Cocaine (uno fermato da un altro
  strumento resta com'è).
- **Schermi abbassati** tornano alla loro luminosità anche dopo un crash, ma solo se mostrano ancora l'abbassamento di
  Cocaine: una luminosità che hai scelto tu dopo viene mantenuta.
- **I risvegli per l'iPhone** programmati da Cocaine vengono annullati (scritti nel fuso orario che il Mac ha quando
  vengono annullati, che è quello che legge `pmset`).
- **Un timer impostato dal Terminale o dall'iPhone** (`cocaine on 90m`, `cocaine remote on --for 2h`) finisce in orario
  anche se Cocaine.app non è aperto: lo spegne l'helper del motore che tiene acceso lo schermo (al massimo con un minuto di
  ritardo), dopo aver controllato l'impostazione dell'app nel caso tu l'abbia cambiata lì.
- **Gli aggiornamenti** non fanno "spegni e riaccendi": durante un aggiornamento con Homebrew o dall'app il Mac resta
  sveglio e la nuova versione prende il posto della vecchia. Se la nuova versione non parte entro 3 minuti, lo stop torna
  come al solito. Se nell'aggiornamento dall'app la nuova versione va in crash, si blocca o non parte, viene rimessa e
  aperta la precedente, che lo dice.
- **L'app eliminata mentre è aperta** (trascinata nel Cestino, sostituita da un'installazione o da un aggiornamento che
  non è riuscito a chiuderla): Cocaine se ne accorge in pochi secondi e si chiude normalmente, rimettendo lo stop; se è
  stata sostituita da un'altra copia, viene aperta quella, che continua la sessione. Funziona perché Cocaine tiene una
  copia del suo motore (e di sé stesso, un clone che su APFS non occupa spazio in più) in
  `~/Library/Application Support/Cocaine/engine/`, aggiornata a ogni avvio.
- **Uno alla volta.** Riaprire Cocaine mentre è già aperto mostra il pannello di quello in esecuzione. Un Cocaine rimasto
  aperto da una copia eliminata viene chiuso e parte quello nuovo. (Un'istanza che sta uscendo, per esempio durante un
  aggiornamento, viene attesa fino a 10 s.)
- **Disinstallare** (`brew uninstall cocaine`) chiede a un Cocaine aperto di uscire (e lo termina se è bloccato), poi
  rimette lo stop e l'indicatore di sistema, chiude gli helper di Cocaine e ne rimuove i file di stato e la copia del
  motore prima di togliere il suo permesso. Se Cocaine non si può chiudere, il permesso resta, così lo stop si può ancora
  rimettere (vedi Limiti). `brew uninstall --zap` rimuove anche `~/Library/Application Support/Cocaine`.

Come: un piccolo watchdog (un processo `zsh` avviato da Cocaine, visibile come
`zsh …/Cocaine.app/Contents/Resources/cocaine watch`) si accorge subito che Cocaine non c'è più e annulla ciò che Cocaine
aveva annotato di aver cambiato (`~/Library/Application Support/Cocaine/recovery.json`). Si ferma solo quando ci è
riuscito: se il ripristino dell'app non può partire (app eliminata, o una nuova versione che va in crash) usa la copia in
`engine/`, e se nemmeno quella va fa da sé l'essenziale (indicatore, risveglio, stop). Se non si può rimettere neppure lo
stop (il permesso non c'è più), l'annotazione resta e il prossimo avvio riprende la sessione. Se il watchdog è stato
terminato insieme all'app, dopo un minuto fa lo stesso l'helper che tiene acceso lo schermo, ancora attivo. Nessun
permesso in più, niente di installato, niente in esecuzione quando Cocaine non lo è (salvo l'helper dello schermo mentre lo
stop è disattivato).

**HUD di sistema e permessi.** Congelare l'indicatore di sistema e mostrare volume e luminosità nell'isola non richiede
permessi. Per gestire da sé i *tasti* di volume e luminosità (passi fini con ⌥⇧) Cocaine ha bisogno di **Accessibilità**,
che chiede quando attivi l'opzione. Senza, macOS cambia comunque volume e luminosità e l'isola li mostra.
(Monitoraggio input non serve.)

**Limiti.**
- Dopo un'interruzione di corrente o un riavvio non è in esecuzione niente di Cocaine: lo stop resta disattivato finché
  qualcosa non interviene (macOS conserva questa impostazione tra i riavvii). Con *Apri al login* lo fa Cocaine al login.
  Altrimenti apri Cocaine, esegui `cocaine off`, oppure `/Applications/Cocaine.app/Contents/MacOS/Cocaine --boot-check`
  (annulla ciò che ha lasciato l'ultima sessione e chiude un timer da Terminale già scaduto; non fa nulla se Cocaine è
  aperto). Cocaine non installa un proprio elemento di login per questo.
- Gli schermi abbassati da Cocaine li può ripristinare solo Cocaine stesso (o la sua copia in `engine/`); l'essenziale di
  ultima istanza del watchdog non può, vengono ripristinati al prossimo avvio.
- Se Cocaine si blocca, viene restituito solo l'indicatore di sistema; lo stop resta com'è finché Cocaine si riprende o
  viene chiuso.
- Se `brew uninstall` non riesce a chiudere un Cocaine aperto, si ferma prima di togliere la regola sudo (la modifica al
  cask che lo fa è in docs/maintainers/cask-changes.md). Finché il tap non la pubblica, una disinstallazione la cui
  chiusura non riesce toglie comunque la regola.
- Il primo aggiornamento *verso* una versione con queste modifiche esegue ancora il passo di disinstallazione della
  versione precedente.
