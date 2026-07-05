
下記の機能、riela note を追加したい。仕様のデザイン、詳細設計、impl-planを作成せよ。実装はしなくてもいい。
riela noteは全ての情報をオントロジーとして管理するnoteでありユーザの知識の全てをそこに詰め込める外部脳として機能する。


## 期待する機能やユースケース
- note とnote bookという概念がある。pdfや本を読み込ませて各ページを1つのnoteとして、作成される。noteの本文はmarkdown形式で表現される。1つのnoteもnotebookとしてデータ設計される
- noteは、本文、タグにはcommentや関連ファイル(画像、動画、音声
- 。埋め込むfileとは別に関連fileとしても扱う),関連noteをつけることもできる。本文の最上段にある"#"のheaderをタイトルとして扱う。 これにより、ある本に人物名や何らかの"年"がある場合、それに関連する情報を説明している noteにリンクされる。またタグは"人物","年","イベント"などのワールモデル的"クラス"などとも紐付けて定義される(その他文書の種類("本","ノート"など) 。タグは基本的にnote作成、編集時にAIによりその文書に追加される。AIがつけたタグ、それがわかるようにする(人間が手動でつけたタグとAIがつけたタグを分けて管理する)
- noteはreadonlyにもできる。read onlyの場合もcommentやタグつけの操作はできる。

- noteの編集、取得はriela workflowの"node",builtin addonとしても準備されている
- ユースケースとして次のようなワークフローができるようにする。chatからpdf fileをattachementする。riela workflowのevent sourceでそのattachmentが受け取られ、pdfの画像か、ocr,文書化(ページ単位)が行われる(ここはすでにrielaで実現可能)その後そのpdfをriela noteとして作成する。各ページにはnote numberが割り振られ、各note とocr元になったfileの画像、note bookと関連付けらる形でpdfの元本のfileとともに保存される。関連fileはスムースに参照でき、textと元になったdocument page画像を素早くswitchすることもできる。(このviewerはmac app,iphone,ipad appを想定,iphone/ipad appのデザインでmac appも作っていい)
- また別のworkflowとしてはyoutube動画をchatではるとriela workflowが動き、その動画のdownload,文字起こしをする。(これはすでにriela でできる)。その文字起こしを1 noteとしてriela noteを作成し、関連動画として保存した動画を関連fileとしてnoteと紐づけて持つ
- fileは"local"または"s3 compatible storage"に保存できる。fileそれぞれが、どの形式で保存されているか(local,or s3)持つようにする。defaultはlocal保存、s3保存とlocal保存が混在してもいい。local 保存しているものをs3保存に移動することもできるように(一括移動もできるといい)

- noteに追加した後にそのnoteに自動で行う操作を設定できる(タグつけなどはdefaultで設定されている)。その操作はriela workflowで表現される。
- note/notebook一覧画面ではdefaultで"登録日"のdescで表示する。list画面ではnotebookの最初のnoteの先頭部分を見せる。

- riela note agent画面を開ける。ここではchatgptなどのようにchat形式で問い合わせられるようにする。Riela note 内のRAGおよびwebからのserchをする(これもworkflowで表現するcodex-agent などで)。ragの場合は元noteへのlinkで辿れるようにする。このagentとの会話も会話のターンをnoteとしてnotebookとして保存できるようにする。(defaultは自動保存、ただし、temp chatを選択したら保存されない(明示的に"保存"ボタンをおすと保存される)

- UIのデザインはなるべくシンプルに。noteの閲覧、検索を軽く行えるようなUIにする

- noteのdatabaseはsqliteを採用。tursoのsdkで使用。

- riela note コマンドでnoteの操作ができる(追加、編集,attachment追加)。graphql で。

- iphone/ipadのclient appはまだ考えなくていい。mac のappは設計したい(つまり自分のmachineで動いているRielaのnoteは操作できるようにしたい)ただし、mac appのデザインはipad/iphoneにも流用できるように(ipad/iphoneように設計されたUIをmac appとして作る)
- riela app,riela serveで起動している時、optionでnote APIを公開できる。外部のマシンからも取得できるようにする。この時のauthは色々な方法を切り替えたい(google 認証,auth0など)ただし当面は"QRコードによるclient登録"を行いたい。+基本的にtailscaleなどでvpn内でのアクセスを前提としたい
- 将来的なユースケースとして、　iphone riela note appで開くとtailscaleで家のmacにアクセスし、そこに保存されているnoteが見れるようになる。
- 当面のusecaseとしては、任意のchat appで速記メモを呟くと、それをriela noteに保存される。タグは"ノート"(必ずつくタグ。本や資料の取り込みなどとは違う),"事業アイデア","哲学","ライフハック"などのように勝手につける。ユーザ体験としては、いちいちノートを開かなくてもその場のアイデアがriela appに体系化されて
- riela note agentとは別にriela note config agent機能を設ける(専用の画面を用意)これは今のriela app agentのように riela noteのconfigをAIが行ってくれるagent. workflowの作成や、つけるべきタグを考えてくれるもの

- notebookの種類(取り込み資料、agentとの会話のログ、ユーザメモ、、)などは"タグ"の形式で管理する。これらは削除不能のタグとしてつけられる

## 特に考えたいこと
- データベース設計をどうするか
- タグがデータ管理に重要であるため、タグのデータ構造の設計
- riela noteの実現のためにriela 本体に足りない機能があればそれもデザイン、実装する
