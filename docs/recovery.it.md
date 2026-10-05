### Niente sopravvive a Cocaine

Aprire Cocaine lo accende; chiuderlo rimette le cose come stavano. Ora vale anche quando Cocaine non si chiude normalmente:

- **Stop.** Cocaine ricorda se lo stop era già disattivato *prima* che lo disattivasse lui (da te, con `pmset`, o da
  un'altra app). Quando ha finito — Esci, logout, `kill`, Ctrl-C, un crash o `kill -9` — lo stop torna com'era prima,
  a meno che nel frattempo qualcuno l'abbia cambiato (allora resta quella modifica). Spegnere Cocaine con il suo
  interruttore, dall'iPhone o con `cocaine off` resta uno spegnimento esplicito. L'helper che tiene acceso lo schermo si
  chiude insieme a lui. Comandi dati nello stesso istante dall'app, dall'iPhone e dal Terminale non si intralciano più.
- **Indicatori di sistema.** Con *Sostituisci HUD di sistema* attivo, l'indicatore di volume/luminosità di macOS resta
  congelato finché Cocaine è aperto. Se Cocaine va in crash o viene terminato, l'indicatore torna entro un paio di secondi;
  se Cocaine si blocca, dopo 30 secondi.
- **Schermi abbassati** tornano alla loro luminosità anche dopo un crash, ma solo se mostrano ancora l'abbassamento di
  Cocaine: una luminosità che hai scelto tu dopo viene mantenuta.
- **I risvegli per l'iPhone** programmati da Cocaine vengono annullati.
- **Gli aggiornamenti** non fanno "spegni e riaccendi": durante un aggiornamento con Homebrew il Mac resta sveglio e la
  nuova versione prende il posto della vecchia. Se la nuova versione non parte entro 3 minuti, lo stop torna come al solito.
- **Uno alla volta.** Una seconda copia di Cocaine aperta mentre una è già attiva si fa da parte (dopo aver atteso fino
  a 10 s nel caso la prima stia uscendo).
- **Disinstallare** (`brew uninstall cocaine`) rimette lo stop e l'indicatore di sistema, chiude gli helper di Cocaine e
  ne rimuove i file di stato prima di togliere il suo permesso. `brew uninstall --zap` rimuove anche
  `~/Library/Application Support/Cocaine`.

Come: un piccolo watchdog (un processo `zsh` avviato da Cocaine, visibile come
`zsh …/Cocaine.app/Contents/Resources/cocaine watch`) si accorge subito che Cocaine non c'è più e annulla ciò che Cocaine
aveva annotato di aver cambiato (`~/Library/Application Support/Cocaine/recovery.json`). Nessun permesso in più, niente di
installato, niente in esecuzione quando Cocaine non lo è.

**HUD di sistema e permessi (correzione).** Congelare l'indicatore di sistema e mostrare volume e luminosità nell'isola
non richiede permessi. Per gestire da sé i *tasti* di volume e luminosità (passi fini con ⌥⇧) Cocaine ha bisogno di
**Accessibilità**, che chiede quando attivi l'opzione. Senza, macOS cambia comunque volume e luminosità e l'isola li mostra.
(Monitoraggio input non serve.)

**Limiti.**
- Se vengono terminati *insieme* Cocaine e il suo watchdog (per esempio `kill -9` di entrambi, o un'interruzione di
  corrente), in quel momento nessuno può intervenire: l'indicatore di sistema torna al logout successivo o alla prossima
  apertura di Cocaine; schermi abbassati e risvegli vengono sistemati alla prossima apertura di Cocaine.
- Dopo un'interruzione di corrente o un riavvio forzato lo stop resta disattivato finché Cocaine non viene riaperto (macOS
  conserva questa impostazione tra i riavvii). Con *Apri al login* succede da solo al login; altrimenti apri Cocaine, o
  esegui `cocaine off`.
- Se Cocaine si blocca, viene restituito solo l'indicatore di sistema; lo stop resta com'è finché Cocaine si riprende o
  viene chiuso.
- Il primo aggiornamento *verso* questa versione esegue ancora il passo di disinstallazione della versione precedente,
  che riattiva lo stop una volta; il passaggio di consegne funziona dall'aggiornamento successivo.
