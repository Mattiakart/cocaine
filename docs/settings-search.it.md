# Ricerca nelle impostazioni

Cocaine ha molte impostazioni. Il campo in cima al pannello Impostazioni le trova tutte a partire da quello che scrivi, con
parole tue, in qualsiasi lingua dell'app, e ti porta lì.

## Come si usa

- Fai clic sul campo, premi **⌘F**, oppure inizia semplicemente a scrivere una lettera in un punto qualsiasi del pannello.
- Scrivi qualsiasi cosa: il nome di un'impostazione o una sua parte (`lingu`), una parola dell'argomento (`luminosità`,
  `wifi`, `password`), una parola in un'altra lingua (`brightness`, `Helligkeit`, `明るさ`), o con un errore di battitura
  (`apunti`, `bateria`).
- **↑ ↓** scorrono i risultati, **Invio** apre quello evidenziato, **Esc** cancella la ricerca (un secondo Esc chiude il
  pannello). Anche un clic apre un risultato; scegliere una scheda durante la ricerca porta a quella scheda.
- Aprire un risultato passa alla sua scheda, scorre fino alla riga (o alla scheda) e la illumina per circa due secondi.
- Ogni risultato dice dove si trova (*Automazioni › Attivazione automatica*) e, quando ha trovato attraverso una parola
  collegata, quale (*≈ luminosità tastiera*).
- Le impostazioni dell'isola si trovano anche con l'isola spenta: il risultato dice di attivare prima *Mostra nel notch* e
  aprirlo porta a quell'interruttore.

## Come trova

Tutto avviene sul Mac: nulla viene inviato e nessun modello viene interpellato.

1. **L'indice** (`Sources/SettingsIndex.swift`): ogni impostazione del pannello con scheda, riquadro e riga, la descrizione e i
   *concetti* di cui tratta. I nomi sono le stringhe del pannello, quindi ogni impostazione si trova col suo nome in tutte le
   8 lingue insieme (la lingua attuale dell'app pesa un po' di più).
2. **Concetti** (`Localization/<lingua>.lproj/SearchIndex.strings`): per circa 60 argomenti (luminosità, caricatore, appunti,
   privacy, agenti IA…) le parole che si usano, in ogni lingua: sinonimi, parole collegate, nomi di prodotti (`teams`,
   `spotify`, `claude`), modi comuni di dirlo (`avvio automatico`, `start at login`).
3. **Normalizzazione**: maiuscole, accenti, caratteri a larghezza piena e separatori non contano (`Wi‑Fi` = `wifi`,
   `luminosita` = `luminosità`). Le parole vuote comuni (`il`, `di`, `the`…) sono ignorate.
4. **Confronto di ogni parola**: parola esatta, poi inizio (`agg` → *Aggiornamenti*), poi parte di parola, poi errori di
   battitura (uno per parole di 4–6 lettere, due da 7; due lettere scambiate contano uno), anche sull'inizio di una parola più
   lunga. Cinese e giapponese sono cercati dentro le frasi.
5. **Parole collegate** (facoltative): per una parola che non trova nulla di buono, gli embedding di parole di macOS sul
   dispositivo (NaturalLanguage: inglese, italiano, spagnolo, francese e tedesco dove installati) suggeriscono parole vicine e
   la forma base della parola; valgono metà. Dove macOS non ha embedding la ricerca funziona uguale.
6. **Ordine**: ogni parola della ricerca deve trovare qualcosa (da tre parole in su, una può mancare); conta di più il nome
   dell'impostazione, poi i concetti, il riquadro, la descrizione. Un nome che inizia con quello che hai scritto viene prima.
   I risultati molto sotto il migliore vengono tolti.

## Aggiungere un'impostazione

Una riga nel suo riquadro in `Sources/SettingsIndex.swift` (la chiave del titolo della riga come la mostra il pannello, la
chiave della descrizione, i concetti). `--ui-test` fallisce finché ogni riga e riquadro disegnati dal pannello non sono
nell'indice, ogni chiave è tradotta e ogni concetto ha parole in tutte le 8 lingue. I nuovi concetti vanno in
`SearchIndex.strings` in tutte le 8 lingue.

## Test

`--ui-test` (in `verify.sh`): normalizzazione, distanza degli errori, ~40 ricerche in 8 lingue che devono trovare la loro
impostazione tra le prime, parole senza senso che non trovano nulla, velocità (ogni ricerca ben sotto i 25 ms), le parole
collegate tramite uno stub e il loro ripiego senza errori, la copertura dell'indice di ogni scheda in 4 lingue. Immagini:
`--render-panel out.png --search "luminosità"`, `--lit "Smart Triggers|Power"` (una riga illuminata).
