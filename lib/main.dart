
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:url_launcher/url_launcher.dart';

void main() => runApp(const NezhaApp());

class NezhaApp extends StatelessWidget {
  const NezhaApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: '導航管家 Pro V9.4',
    theme: ThemeData.dark(useMaterial3: true).copyWith(
      scaffoldBackgroundColor: const Color(0xff07111f),
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xffff8a00), brightness: Brightness.dark),
    ),
    home: const Home(),
  );
}

class Place {
  String name, address, entry, parking, note;
  bool done;
  Place(this.name, this.address, {this.entry='', this.parking='', this.note='', this.done=false});
}

enum Engine { google, waze }
enum Mood { normal, happy, think, warn }

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with TickerProviderStateMixin {
  late AnimationController floatCtrl;
  final tts = FlutterTts();
  final speech = stt.SpeechToText();
  StreamSubscription<Position>? gpsSub;
  StreamSubscription<AccelerometerEvent>? accelSub;

  final quick = TextEditingController();
  final ai = TextEditingController();
  final name = TextEditingController();
  final addr = TextEditingController();
  final entry = TextEditingController();
  final park = TextEditingController();
  final note = TextEditingController();

  int tab = 0;
  bool listening=false, speechReady=false, trip=false, rec=false, gpsOn=false, permOk=false;
  Mood mood = Mood.normal;
  Position? pos;
  double speed=0, shock=0;
  DateTime lastShock = DateTime.fromMillisecondsSinceEpoch(0);
  String destination = '';
  int warnings = 0;

  final chat = <Map<String,String>>[
    {'ai':'V9.4已補上導航入口。你可以輸入目的地、選地點，然後一鍵開 Google 或 Waze。'}
  ];

  final places = <Place>[
    Place('王先生','台北車站', entry:'台北車站南二門', parking:'台北車站停車場', note:'不要導到後門'),
    Place('李小姐','台中火車站', entry:'台中火車站前站', parking:'台中火車站停車場', note:'先提醒入口'),
  ];

  @override
  void initState(){
    super.initState();
    floatCtrl = AnimationController(vsync:this, duration: const Duration(milliseconds:1800))..repeat(reverse:true);
    init();
  }

  Future<void> init() async {
    await [Permission.location, Permission.microphone, Permission.camera].request();
    await tts.setLanguage('zh-TW');
    await tts.setPitch(1.45);
    await tts.setSpeechRate(0.62);
    speechReady = await speech.initialize(onStatus:(s){ if((s=='done'||s=='notListening')&&mounted)setState(()=>listening=false); });
    await startGps();
    startSensors();
    say('V9.4啟動，這次可以設定目的地和一鍵導航了。', Mood.happy);
  }

  String face()=> switch(mood){Mood.normal=>'😊', Mood.happy=>'😄', Mood.think=>'🤔', Mood.warn=>'😠'};
  String speakLine(String t, Mood m)=> switch(m){Mood.warn=>'欸！$t', Mood.happy=>'$t，穩穩來～', Mood.think=>'我想一下喔，$t', Mood.normal=>t};

  Future<void> say(String text, [Mood m=Mood.normal]) async {
    setState(()=>mood=m);
    await tts.stop();
    await tts.setPitch(m==Mood.warn?1.52:1.43);
    await tts.setSpeechRate(0.62);
    await tts.speak(speakLine(text,m));
  }

  Future<void> startGps() async {
    gpsOn = await Geolocator.isLocationServiceEnabled();
    var p = await Geolocator.checkPermission();
    if(p==LocationPermission.denied) p = await Geolocator.requestPermission();
    permOk = p==LocationPermission.always || p==LocationPermission.whileInUse;
    setState((){});
    if(!gpsOn || !permOk){
      chat.add({'ai':'定位權限還沒好。導航可以開，但速度與位置提醒會不準。'});
      return;
    }
    try {
      final now = await Geolocator.getCurrentPosition(desiredAccuracy:LocationAccuracy.bestForNavigation, timeLimit: const Duration(seconds:12));
      pos=now; speed=math.max(0, now.speed*3.6); setState((){});
    } catch (_) {}
    gpsSub?.cancel();
    gpsSub = Geolocator.getPositionStream(locationSettings: const LocationSettings(accuracy:LocationAccuracy.bestForNavigation, distanceFilter:2)).listen((p){
      pos=p; speed=math.max(0,p.speed*3.6); setState((){});
      if(trip && speed>75) say('現在速度有點快，穩一下啦。', Mood.warn);
    });
  }

  void startSensors(){
    accelSub?.cancel();
    accelSub = accelerometerEventStream().listen((e){
      final f = math.sqrt(e.x*e.x+e.y*e.y+e.z*e.z);
      final d = (f-shock).abs();
      shock=f;
      if(trip && d>18 && DateTime.now().difference(lastShock).inSeconds>8){
        lastShock=DateTime.now();
        warnings++;
        chat.add({'ai':'剛剛那一下有點猛，我幫你標記成安全事件。'});
        say('剛剛那一下有點猛，我幫你標記起來。', Mood.warn);
        setState((){});
      }
    });
  }

  String bestTarget(Place p) => p.entry.trim().isNotEmpty ? p.entry.trim() : (p.parking.trim().isNotEmpty ? p.parking.trim() : p.address.trim());

  Future<void> openNav(String target, Engine engine) async {
    if(target.trim().isEmpty){ say('你還沒輸入目的地啦。', Mood.warn); return; }
    destination=target.trim();
    trip=true; rec=true;
    chat.add({'ai':'目的地已設定：$destination。我會提醒入口、停車、安全事件，並開啟導航。'});
    setState(()=>mood=Mood.happy);
    say('目的地設定好了，準備開導航。', Mood.happy);

    final encoded = Uri.encodeComponent(destination);
    final uri = engine==Engine.waze
      ? Uri.parse('https://waze.com/ul?q=$encoded&navigate=yes')
      : Uri.parse('google.navigation:q=$encoded&mode=d');
    final fallback = Uri.parse('https://www.google.com/maps/search/?api=1&query=$encoded');
    try {
      final ok = await launchUrl(uri, mode:LaunchMode.externalApplication);
      if(!ok) await launchUrl(fallback, mode:LaunchMode.externalApplication);
    } catch (_) {
      try { await launchUrl(fallback, mode:LaunchMode.externalApplication); }
      catch (_) { say('開導航失敗，請確認手機有安裝 Google Maps 或 Waze。', Mood.warn); }
    }
  }

  void savePlace(){
    if(name.text.trim().isEmpty || addr.text.trim().isEmpty){ say('名稱和地址要先填啦。', Mood.warn); return; }
    places.add(Place(name.text.trim(), addr.text.trim(), entry:entry.text.trim(), parking:park.text.trim(), note:note.text.trim()));
    name.clear(); addr.clear(); entry.clear(); park.clear(); note.clear();
    chat.add({'ai':'新地點已存好。下次可以直接選它導航。'});
    say('地點存好了，下次我幫你提醒入口。', Mood.happy);
    setState(()=>tab=2);
  }

  void ask(){
    final q=ai.text.trim();
    if(q.isEmpty) return;
    ai.clear(); chat.add({'user':q}); setState(()=>mood=Mood.think);
    String a; Mood m=Mood.normal;
    if(q.contains('導航')||q.contains('目的地')){a='到導航首頁輸入目的地，或到地點頁選客戶，再按 Google 或 Waze。'; m=Mood.happy;}
    else if(q.contains('停車')) a='先不要硬停門口。建議目的地附近 100 到 300 公尺找停車點。';
    else if(q.contains('入口')) a='地點頁可以記入口。下次我會優先提醒入口，避免導到後門。';
    else if(q.contains('錄影')) a=rec?'目前錄影狀態已開，遇到震動我會標記。':'目前沒有錄影，開始導航會自動開。';
    else if(q.contains('定位')||q.contains('在哪')) a=pos==null?'目前還沒抓到GPS，先到安全頁按重新定位。':'定位有了，速度約 ${speed.toStringAsFixed(0)} 公里，精準度約 ${pos!.accuracy.toStringAsFixed(0)} 公尺。';
    else a='我會幫你做三件事：設定目的地、一鍵開導航、提醒入口停車與安全。';
    chat.add({'ai':a}); setState(()=>mood=m); say(a,m);
  }

  void toggleListen() async {
    if(!speechReady) speechReady = await speech.initialize();
    if(listening){ await speech.stop(); setState(()=>listening=false); return; }
    setState(()=>listening=true);
    await speech.listen(localeId:'zh_TW', onResult:(r){ if(r.finalResult){ ai.text=r.recognizedWords; ask(); }});
  }

  @override
  void dispose(){gpsSub?.cancel(); accelSub?.cancel(); floatCtrl.dispose(); quick.dispose(); ai.dispose(); name.dispose(); addr.dispose(); entry.dispose(); park.dispose(); note.dispose(); tts.stop(); super.dispose();}

  @override
  Widget build(BuildContext context){
    final pages=[navPage(), aiPage(), placesPage(), addPage(), safePage()];
    return Scaffold(
      body: SafeArea(child:pages[tab]),
      bottomNavigationBar: NavigationBar(
        selectedIndex:tab,
        onDestinationSelected:(i)=>setState(()=>tab=i),
        backgroundColor: const Color(0xee07111f),
        destinations: const [
          NavigationDestination(icon:Icon(Icons.navigation),label:'導航'),
          NavigationDestination(icon:Icon(Icons.smart_toy),label:'哪吒'),
          NavigationDestination(icon:Icon(Icons.place),label:'地點'),
          NavigationDestination(icon:Icon(Icons.add_location_alt),label:'新增'),
          NavigationDestination(icon:Icon(Icons.shield),label:'安全'),
        ],
      ),
    );
  }

  Widget shell(Widget child)=>Container(decoration: const BoxDecoration(gradient:RadialGradient(center:Alignment(-.9,-1),radius:1.35,colors:[Color(0xff174166),Color(0xff07111f),Color(0xff030812)])),child:child);

  Widget header()=>Row(children:[
    Container(width:54,height:54,decoration:BoxDecoration(gradient:const LinearGradient(colors:[Color(0xffff9f1c),Color(0xffff4d6d)]),borderRadius:BorderRadius.circular(18),boxShadow:const[BoxShadow(color:Color(0x55ff9f1c),blurRadius:24,offset:Offset(0,8))]),child:const Center(child:Text('🔥',style:TextStyle(fontSize:28)))),
    const SizedBox(width:12),
    const Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('導航管家 Pro V9.4',style:TextStyle(fontSize:20,fontWeight:FontWeight.w900)),Text('AI安全管家 + 一鍵導航',style:TextStyle(color:Colors.white60,fontSize:13))])),
    chip('BOSS', Colors.greenAccent),
  ]);

  Widget navPage()=>shell(ListView(padding:const EdgeInsets.all(16),children:[
    header(), const SizedBox(height:14), hero(), const SizedBox(height:14),
    card(Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      const Text('設定目的地',style:TextStyle(fontSize:22,fontWeight:FontWeight.w900)),
      const SizedBox(height:6),
      const Text('這裡是真正導航入口：輸入地址或選地點，一鍵開 Google/Waze。',style:TextStyle(color:Colors.white70)),
      const SizedBox(height:12),
      TextField(controller:quick,decoration:field('輸入目的地 / 地址 / 店名')),
      const SizedBox(height:10),
      Row(children:[Expanded(child:primary('Google導航',()=>openNav(quick.text,Engine.google))),const SizedBox(width:10),Expanded(child:secondary('Waze導航',()=>openNav(quick.text,Engine.waze)))]),
      const SizedBox(height:8),
      secondary('選擇已存地點',()=>setState(()=>tab=2)),
    ])),
    const SizedBox(height:14),
    card(Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('哪吒提醒',style:TextStyle(fontWeight:FontWeight.w900,fontSize:18)),const SizedBox(height:6),Text(destination.isEmpty?'尚未設定目的地。':'目前目的地：$destination',style:const TextStyle(color:Colors.white70)),Text('REC：${rec?'錄影中':'未錄影'}｜GPS：${pos==null?'未定位':'已定位'}',style:const TextStyle(color:Colors.white70))])),
  ]));

  Widget hero()=>AnimatedBuilder(animation:floatCtrl,builder:(_,__){
    final y=math.sin(floatCtrl.value*math.pi)*10;
    return Container(height:250,decoration:BoxDecoration(borderRadius:BorderRadius.circular(30),gradient:const LinearGradient(colors:[Color(0x332dd4ff),Color(0x33ff9f1c),Color(0x227a5cff)]),border:Border.all(color:Colors.white.withOpacity(.13))),child:Stack(children:[
      Positioned.fill(child:CustomPaint(painter:GridPainter())),
      Positioned(left:35,right:35,top:135,child:Container(height:10,decoration:BoxDecoration(gradient:const LinearGradient(colors:[Color(0xffffe066),Color(0xffff9f1c),Color(0xff00d4ff)]),borderRadius:BorderRadius.circular(99),boxShadow:const[BoxShadow(color:Color(0x99ffe066),blurRadius:24)]))),
      const Positioned(left:45,bottom:48,child:Text('🚗',style:TextStyle(fontSize:32))),
      const Positioned(right:58,top:72,child:Text('🧭',style:TextStyle(fontSize:36))),
      const Positioned(right:95,bottom:52,child:Text('📸',style:TextStyle(fontSize:30))),
      Positioned(left:88,top:66+y,child:Text('👦🏻🔥 ${face()}',style:const TextStyle(fontSize:82,shadows:[Shadow(color:Color(0xffff9f1c),blurRadius:24)]))),
      Positioned(right:18,top:18,child:chip(rec?'🔴 REC':'REC OFF',rec?Colors.redAccent:Colors.white54)),
      Positioned(left:18,bottom:18,right:18,child:Container(padding:const EdgeInsets.all(12),decoration:BoxDecoration(color:Colors.black.withOpacity(.35),borderRadius:BorderRadius.circular(18)),child:Text(speakLine('輸入目的地後，我幫你開導航、提醒入口停車。',mood),style:const TextStyle(fontWeight:FontWeight.w700)))),
    ]));
  });

  Widget aiPage()=>shell(Column(children:[
    Padding(padding:const EdgeInsets.all(16),child:header()),
    Expanded(child:ListView.builder(padding:const EdgeInsets.symmetric(horizontal:16),itemCount:chat.length,itemBuilder:(_,i){
      final m=chat[i]; final isAi=m.containsKey('ai');
      return Align(alignment:isAi?Alignment.centerLeft:Alignment.centerRight,child:Container(margin:const EdgeInsets.only(bottom:10),padding:const EdgeInsets.all(14),constraints:const BoxConstraints(maxWidth:330),decoration:BoxDecoration(color:isAi?Colors.orange.withOpacity(.15):Colors.blue.withOpacity(.18),borderRadius:BorderRadius.circular(18),border:Border.all(color:Colors.white.withOpacity(.10))),child:Text(isAi?'哪吒：${m['ai']}':m['user']!,style:const TextStyle(height:1.35))));
    })),
    Container(padding:const EdgeInsets.all(12),color:const Color(0xee07111f),child:Row(children:[IconButton.filled(onPressed:toggleListen,icon:Icon(listening?Icons.stop:Icons.mic)),const SizedBox(width:8),Expanded(child:TextField(controller:ai,decoration:field(listening?'我在聽...':'問哪吒：導航？停車？入口？定位？'),onSubmitted:(_)=>ask())),const SizedBox(width:8),IconButton.filled(onPressed:ask,icon:const Icon(Icons.send))]))
  ]));

  Widget placesPage()=>shell(ListView(padding:const EdgeInsets.all(16),children:[
    header(), const SizedBox(height:14), const Text('已存地點',style:TextStyle(fontSize:22,fontWeight:FontWeight.w900)), const SizedBox(height:10),
    for(final p in places) placeCard(p),
  ]));

  Widget placeCard(Place p)=>Container(margin:const EdgeInsets.only(bottom:12),child:card(Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
    Row(children:[Expanded(child:Text(p.name,style:const TextStyle(fontSize:20,fontWeight:FontWeight.w900))),if(p.done)chip('完成',Colors.greenAccent)]),
    const SizedBox(height:6),
    Text('地址：${p.address}\n入口：${p.entry.isEmpty?'未設定':p.entry}\n停車：${p.parking.isEmpty?'未設定':p.parking}\n備註：${p.note.isEmpty?'無':p.note}',style:const TextStyle(color:Colors.white70,height:1.45)),
    const SizedBox(height:10),
    Row(children:[Expanded(child:primary('Google',()=>openNav(bestTarget(p),Engine.google))),const SizedBox(width:8),Expanded(child:secondary('Waze',()=>openNav(bestTarget(p),Engine.waze))),const SizedBox(width:8),Expanded(child:secondary('完成',(){setState(()=>p.done=true); say('這站完成了。',Mood.happy);} ))])
  ])));

  Widget addPage()=>shell(ListView(padding:const EdgeInsets.all(16),children:[
    header(), const SizedBox(height:14),
    card(Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      const Text('新增客戶 / 常用地點',style:TextStyle(fontSize:22,fontWeight:FontWeight.w900)),
      const SizedBox(height:12),
      TextField(controller:name,decoration:field('名稱，例如：王先生 / 公司 / 家')),
      const SizedBox(height:10),
      TextField(controller:addr,decoration:field('地址')),
      const SizedBox(height:10),
      TextField(controller:entry,decoration:field('入口位置，可不填')),
      const SizedBox(height:10),
      TextField(controller:park,decoration:field('停車點，可不填')),
      const SizedBox(height:10),
      TextField(controller:note,decoration:field('備註，例如：不要導到後門')),
      const SizedBox(height:12),
      primary('儲存地點',savePlace),
    ]))
  ]));

  Widget safePage()=>shell(ListView(padding:const EdgeInsets.all(16),children:[
    header(), const SizedBox(height:14),
    card(Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      const Text('安全 / GPS狀態',style:TextStyle(fontSize:22,fontWeight:FontWeight.w900)),
      const SizedBox(height:10),
      lineRow('手機GPS',gpsOn?'已開':'未開',gpsOn),
      lineRow('定位權限',permOk?'允許':'未允許',permOk),
      lineRow('目前速度','${speed.toStringAsFixed(1)} km/h',speed<=75),
      lineRow('錄影狀態',rec?'錄影中':'未錄影',rec),
      const SizedBox(height:10),
      Text(pos==null?'尚未定位':'緯度：${pos!.latitude.toStringAsFixed(6)}\n經度：${pos!.longitude.toStringAsFixed(6)}\n精準度：${pos!.accuracy.toStringAsFixed(0)}m',style:const TextStyle(color:Colors.white70,height:1.5)),
      const SizedBox(height:10),
      primary('重新定位', startGps),
      const SizedBox(height:8),
      secondary('開啟權限設定', openAppSettings),
    ])),
    const SizedBox(height:14),
    card(Text('震動值：${shock.toStringAsFixed(1)}\n安全事件：$warnings',style:const TextStyle(color:Colors.white70,height:1.6)))
  ]));

  Widget card(Widget child)=>Container(padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:const Color(0xbb13273e),borderRadius:BorderRadius.circular(24),border:Border.all(color:Colors.white.withOpacity(.12)),boxShadow:const[BoxShadow(color:Color(0x33000000),blurRadius:28,offset:Offset(0,14))]),child:child);
  Widget chip(String text,Color color)=>Container(padding:const EdgeInsets.symmetric(horizontal:10,vertical:6),decoration:BoxDecoration(color:color.withOpacity(.18),borderRadius:BorderRadius.circular(99)),child:Text(text));
  Widget lineRow(String a,String b,bool ok)=>Padding(padding:const EdgeInsets.only(bottom:8),child:Row(children:[Icon(ok?Icons.check_circle:Icons.error,color:ok?Colors.greenAccent:Colors.orange),const SizedBox(width:8),Expanded(child:Text(a)),Text(b,style:TextStyle(color:ok?Colors.greenAccent:Colors.orange))]));
  InputDecoration field(String hint)=>InputDecoration(hintText:hint,filled:true,fillColor:Colors.white.withOpacity(.08),border:OutlineInputBorder(borderRadius:BorderRadius.circular(18),borderSide:BorderSide.none));
  Widget primary(String text,VoidCallback onTap)=>FilledButton(onPressed:onTap,style:FilledButton.styleFrom(padding:const EdgeInsets.symmetric(vertical:14),backgroundColor:const Color(0xffff7a1a),shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(16))),child:Text(text,style:const TextStyle(fontWeight:FontWeight.w900)));
  Widget secondary(String text,VoidCallback onTap)=>OutlinedButton(onPressed:onTap,style:OutlinedButton.styleFrom(padding:const EdgeInsets.symmetric(vertical:14),side:BorderSide(color:Colors.white.withOpacity(.18)),shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(16))),child:Text(text));
}

class GridPainter extends CustomPainter{
  @override void paint(Canvas canvas,Size size){ final p=Paint()..color=Colors.white.withOpacity(.055)..strokeWidth=1; for(double x=-80;x<size.width+120;x+=42){canvas.drawLine(Offset(x,size.height),Offset(x+140,0),p);} for(double y=0;y<size.height+80;y+=42){canvas.drawLine(Offset(0,y),Offset(size.width,y-80),p);} }
  @override bool shouldRepaint(covariant CustomPainter oldDelegate)=>false;
}
