### Come è protetto il controllo da iPhone (protocollo v2)

Ogni Comando Rapido creato da *Lavoro da remoto → iPhone → Invia* contiene una propria chiave casuale da 256 bit (oltre ai due
canali casuali sul relay). Grazie a questa:

- **Comandi e risposte sono cifrati end-to-end.** Il relay (ntfy.sh o il tuo server) vede solo testo cifrato, un numero casuale e
  un orario: non il comando, non lo stato, i nomi dei progetti o l'output degli agenti. Sul relay tutti i comandi hanno la stessa lunghezza.
- **Ogni messaggio è autenticato.** Un comando senza la chiave giusta viene ignorato, e così una risposta sull'iPhone. Conoscere i
  canali del relay (per esempio il gestore del relay) non basta più per comandare il Mac o falsificare una risposta.
- **Niente replay.** Ogni comando porta un numero usa-e-getta e l'ora dell'iPhone. Il Mac esegue un comando al massimo una volta:
  ciò che ha eseguito viene salvato su disco (`remote-state.json`, scrittura atomica) prima di eseguirlo, quindi i duplicati che il
  relay riconsegna dopo una riconnessione, un risveglio, un crash o un riavvio vengono scartati. I comandi più vecchi di 2 minuti
  (20 con *Sveglia per iPhone*) o datati nel futuro vengono rifiutati.
- **Le risposte appartengono alla loro richiesta.** L'iPhone mostra solo la risposta al comando appena inviato; *Ultima risposta*
  mostra la risposta autentica più recente degli ultimi 30 minuti.
- **Revoca e scadenza.** *Revoca* ha effetto subito (anche un comando in corso non riceve risposta). Un abbinamento scade dopo 180
  giorni: il suo Comando Rapido lo dice; inviane uno nuovo.
- I comandi passano sempre dalla stessa lista fissa di comandi consentiti (`cocaine remote gate`); ciò che scrivi non finisce mai in una riga di shell.

**I Comandi Rapidi creati prima di questa versione** inviano testo in chiaro, non autenticato. Dopo l'aggiornamento smettono di
funzionare: eseguendone uno compare "Cocaine è stato aggiornato e non accetta più questo Comando Rapido…", e nel pannello appare la
riga arancione *Comandi Rapidi vecchi*. Invia un nuovo Comando Rapido (ed elimina il vecchio sull'iPhone), poi premi *Rimuovi*. Se ti
servono alcuni giorni, *Consenti 14 giorni* lascia ai vecchi Comandi Rapidi **solo stato, on/off, progetti, agenti ed elenco lavori**
(mai avviare o guidare agenti) fino alla data indicata: nel frattempo non sono protetti.

**Limiti, onestamente.** L'app Comandi Rapidi non ha un'azione di cifratura, quindi il Comando Rapido la realizza con SHA-256/SHA-512,
Base64 ed espressioni regolari (un cifrario a flusso basato su hash e un hash con chiave annidato, costruzioni standard, verificati
contro il codice CryptoKit del Mac). Per questo il Comando Rapido è grande (circa 650 azioni) e un comando richiede qualche secondo
sull'iPhone; le risposte oltre circa 2.800 byte vengono troncate. La chiave sta nel file del Comando Rapido e sul Mac in `phones.json`
(leggibile solo da te): chi ottiene il Comando Rapido può ancora usarlo, e si sincronizza via iCloud come ogni Comando Rapido — trattalo
come una chiave. Il relay vede ancora *quando* e *quanto spesso* invii comandi, e può ritardarli o scartarli (vedrai "Nessuna risposta
valida per ora"); un comando accettato dal Mac subito prima di un crash non viene eseguito (mai due volte). Il Comando Rapido generato
è stato eseguito davvero nell'app Comandi Rapidi su un Mac (macOS 27, lingua italiana) tramite ntfy.sh — Stato, un comando digitato
con accenti e simboli, una risposta da 2.800 byte, *Ultima risposta*, una risposta falsificata — ma non ancora su un iPhone. La prima
esecuzione chiede una volta di consentire la connessione a ntfy.sh (o al tuo relay): consentila.

**Se l'iPhone mostra "Nessuna risposta valida per ora".** Il Mac scrive una riga per ogni messaggio del telefono in
`~/Library/Application Support/Cocaine/remote-phone.log`: `accepted`, `reply-sent` (o `reply-failed` con lo stato HTTP del relay),
oppure il motivo del rifiuto — `malformed` (con la forma del messaggio: numero e lunghezza dei campi), `bad-tag` (un'altra chiave:
un Comando Rapido vecchio o modificato), `stale`/`future` (con l'età: controlla gli orologi di iPhone e Mac), `replay`, `expired`,
`revoked`, `unknown-pairing`, `decrypt-failed`, `legacy-refused` — più `relay-up`/`relay-down` per la connessione del Mac. Non contiene
mai una chiave, un canale, un comando o una risposta. I Comandi Rapidi creati dalle prime versioni v2, prima di questa correzione, non
hanno mai funzionato (le azioni Genera hash non ricevevano l'input, quindi i comandi arrivavano senza tag): eliminali e inviane uno nuovo.
