
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
    title: '導航管家 Pro V10.1',
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

class SpeedCam {
  final String name; final double lat,lng; final int limit;
  SpeedCam(this.name,this.lat,this.lng,this.limit);
}

enum Engine { waze, google }
enum Mood { normal, happy, think, warn, angry }

class Home extends StatefulWidget {
  const Home({super.key});
  @override State<Home> createState()=>_HomeState();
}

class _HomeState extends State<Home> with TickerProviderStateMixin {
  late AnimationController floatCtrl;
  final tts=FlutterTts();
  final speech=stt.SpeechToText();
  final quick=TextEditingController(), ai=TextEditingController();
  final name=TextEditingController(), addr=TextEditingController(), entry=TextEditingController(), park=TextEditingController(), note=TextEditingController();
  StreamSubscription<Position>? gpsSub;
  StreamSubscription<AccelerometerEvent>? accelSub;

  int tab=0, warnings=0;
  bool listening=false, speechReady=false, trip=false, rec=false, gpsOn=false, permOk=false;
  Mood mood=Mood.normal;
  Position? pos;
  double speed=0, shock=0;
  String destination='', speedCamText='尚未接近測速點';
  DateTime lastShock=DateTime.fromMillisecondsSinceEpoch(0);
  DateTime lastCamWarn=DateTime.fromMillisecondsSinceEpoch(0);

  final chat=<Map<String,String>>[
    {'ai':'V10.1啟動。預設 Waze 真導航，Google 備用，並加入測速照相提醒。'}
  ];
  final places=<Place>[
    Place('王先生','台北車站',entry:'台北車站南二門',parking:'台北車站停車場',note:'不要導到後門'),
    Place('李小姐','台中火車站',entry:'台中火車站前站',parking:'台中火車站停車場',note:'先提醒入口'),
  ];
  final cams=<SpeedCam>[
    SpeedCam('台北車站周邊測速示範點',25.0478,121.5170,50),
    SpeedCam('台中車站周邊測速示範點',24.1368,120.6869,50),
    SpeedCam('高雄車站周邊測速示範點',22.6395,120.3020,50),
  ];

  @override void initState(){
    super.initState();
    floatCtrl=AnimationController(vsync:this,duration:const Duration(milliseconds:1800))..repeat(reverse:true);
    init();
  }

  Future<void> init() async{
    await [Permission.location,Permission.microphone].request();
    await tts.setLanguage('zh-TW'); await tts.setPitch(1.45); await tts.setSpeechRate(0.62);
    speechReady=await speech.initialize(onStatus:(s){if((s=='done'||s=='notListening')&&mounted)setState(()=>listening=false);});
    await startGps(); startSensors();
    say('V10.1啟動，Waze導航和測速提醒準備好了。',Mood.happy);
  }

  String line(String t,Mood m)=>switch(m){Mood.warn=>'注意！$t',Mood.angry=>'欸欸！$t',Mood.happy=>'$t，穩穩來～',Mood.think=>'我看一下喔，$t',Mood.normal=>t};
  Future<void> say(String t,[Mood m=Mood.normal]) async{setState(()=>mood=m); await tts.stop(); await tts.setPitch(m==Mood.warn||m==Mood.angry?1.52:1.43); await tts.speak(line(t,m));}

  Future<void> startGps() async{
    gpsOn=await Geolocator.isLocationServiceEnabled();
    var p=await Geolocator.checkPermission();
    if(p==LocationPermission.denied)p=await Geolocator.requestPermission();
    permOk=p==LocationPermission.always||p==LocationPermission.whileInUse;
    setState((){});
    if(!gpsOn||!permOk){chat.add({'ai':'定位權限還沒好。Waze導航可開，但測速距離與速度提醒會不準。'});return;}
    try{final now=await Geolocator.getCurrentPosition(desiredAccuracy:LocationAccuracy.bestForNavigation,timeLimit:const Duration(seconds:12));pos=now;speed=math.max(0,now.speed*3.6);checkCams(now);}catch(_){}
    gpsSub?.cancel();
    gpsSub=Geolocator.getPositionStream(locationSettings:const LocationSettings(accuracy:LocationAccuracy.bestForNavigation,distanceFilter:2)).listen((p){
      pos=p; speed=math.max(0,p.speed*3.6); checkCams(p); setState((){});
      if(trip&&speed>75)say('現在速度偏快，慢一點，小心測速。',Mood.angry);
    });
  }

  void checkCams(Position p){
    SpeedCam? near; double m=999999;
    for(final c in cams){final d=Geolocator.distanceBetween(p.latitude,p.longitude,c.lat,c.lng); if(d<m){m=d;near=c;}}
    if(near!=null&&m<800){
      speedCamText='${near.name}｜約 ${m.toStringAsFixed(0)}m｜速限 ${near.limit}';
      if(trip&&m<350&&DateTime.now().difference(lastCamWarn).inSeconds>45){
        lastCamWarn=DateTime.now(); warnings++;
        final over=speed>near.limit;
        chat.add({'ai':over?'前方約 ${m.toStringAsFixed(0)} 公尺有測速，你現在超過速限，快慢下來。':'前方約 ${m.toStringAsFixed(0)} 公尺有測速照相，注意速限 ${near.limit}。'});
        say(over?'前方有測速，你現在超過速限，快慢下來。':'前方有測速照相，注意速限。',over?Mood.angry:Mood.warn);
      }
    }else{speedCamText='尚未接近測速點';}
  }

  void startSensors(){
    accelSub?.cancel();
    accelSub=accelerometerEventStream().listen((e){
      final f=math.sqrt(e.x*e.x+e.y*e.y+e.z*e.z), d=(f-shock).abs(); shock=f;
      if(trip&&d>18&&DateTime.now().difference(lastShock).inSeconds>8){
        lastShock=DateTime.now(); warnings++; chat.add({'ai':'剛剛那一下太猛，我幫你標記成安全事件。'}); say('剛剛那一下太猛了，我幫你標記起來。',Mood.angry); setState((){});
      }
    });
  }

  String bestTarget(Place p)=>p.entry.trim().isNotEmpty?p.entry.trim():(p.parking.trim().isNotEmpty?p.parking.trim():p.address.trim());

  Future<void> openNav(String target,Engine engine) async{
    if(target.trim().isEmpty){say('你還沒輸入目的地啦。',Mood.angry);return;}
    destination=target.trim(); trip=true; rec=true;
    chat.add({'ai':'目的地已設定：$destination。Waze負責真路況，我負責測速、入口、停車、安全。'});
    setState(()=>mood=Mood.happy);
    say(engine==Engine.waze?'開 Waze 真導航，我在旁邊幫你看測速和安全。':'開 Google 備用導航，我在旁邊幫你看安全。',Mood.happy);
    final enc=Uri.encodeComponent(destination);
    final uri=engine==Engine.waze?Uri.parse('https://waze.com/ul?q=$enc&navigate=yes'):Uri.parse('google.navigation:q=$enc&mode=d');
    final fallback=Uri.parse('https://www.google.com/maps/search/?api=1&query=$enc');
    try{final ok=await launchUrl(uri,mode:LaunchMode.externalApplication); if(!ok)await launchUrl(fallback,mode:LaunchMode.externalApplication);}catch(_){try{await launchUrl(fallback,mode:LaunchMode.externalApplication);}catch(_){say('開導航失敗，請確認手機有安裝 Waze 或 Google Maps。',Mood.angry);}}
  }

  void savePlace(){
    if(name.text.trim().isEmpty||addr.text.trim().isEmpty){say('名稱和地址要先填啦。',Mood.angry);return;}
    places.add(Place(name.text.trim(),addr.text.trim(),entry:entry.text.trim(),parking:park.text.trim(),note:note.text.trim()));
    name.clear();addr.clear();entry.clear();park.clear();note.clear();chat.add({'ai':'新地點已存好。下次可以直接選它導航。'});say('地點存好了。',Mood.happy);setState(()=>tab=2);
  }

  void ask(){
    final q=ai.text.trim(); if(q.isEmpty)return; ai.clear(); chat.add({'user':q}); setState(()=>mood=Mood.think);
    String a; Mood m=Mood.normal;
    if(q.contains('導航')||q.contains('Waze')){a='主畫面輸入目的地後按 Waze導航。Waze負責真路況，我負責入口、停車、測速和安全。';m=Mood.happy;}
    else if(q.contains('測速')||q.contains('照相')){a='接近測速點約 350 公尺會提醒，超速時會加強警告。';m=Mood.warn;}
    else if(q.contains('停車'))a='先不要硬停門口。建議附近 100 到 300 公尺找停車點。';
    else if(q.contains('入口'))a='地點頁可以記入口。導航時我會優先提醒入口，避免導到後門。';
    else if(q.contains('定位'))a=pos==null?'目前還沒抓到GPS，先到安全頁按重新定位。':'定位有了，速度約 ${speed.toStringAsFixed(0)} 公里，精準度約 ${pos!.accuracy.toStringAsFixed(0)} 公尺。';
    else a='我會幫你做四件事：Waze真導航、測速提醒、入口停車、安全錄影。';
    chat.add({'ai':a}); setState(()=>mood=m); say(a,m);
  }

  void toggleListen() async{
    if(!speechReady)speechReady=await speech.initialize();
    if(listening){await speech.stop();setState(()=>listening=false);return;}
    setState(()=>listening=true);
    await speech.listen(localeId:'zh_TW',onResult:(r){if(r.finalResult){ai.text=r.recognizedWords;ask();}});
  }

  @override void dispose(){gpsSub?.cancel();accelSub?.cancel();floatCtrl.dispose();quick.dispose();ai.dispose();name.dispose();addr.dispose();entry.dispose();park.dispose();note.dispose();tts.stop();super.dispose();}

  @override Widget build(BuildContext context){
    final pages=[navPage(),aiPage(),placesPage(),addPage(),speedPage(),safePage()];
    return Scaffold(body:SafeArea(child:pages[tab]),bottomNavigationBar:NavigationBar(selectedIndex:tab,onDestinationSelected:(i)=>setState(()=>tab=i),backgroundColor:const Color(0xee07111f),destinations:const[
      NavigationDestination(icon:Icon(Icons.navigation),label:'導航'),NavigationDestination(icon:Icon(Icons.smart_toy),label:'哪吒'),NavigationDestination(icon:Icon(Icons.place),label:'地點'),NavigationDestination(icon:Icon(Icons.add_location_alt),label:'新增'),NavigationDestination(icon:Icon(Icons.speed),label:'測速'),NavigationDestination(icon:Icon(Icons.shield),label:'安全')
    ]));
  }

  Widget shell(Widget c)=>Container(decoration:const BoxDecoration(gradient:RadialGradient(center:Alignment(-.9,-1),radius:1.35,colors:[Color(0xff174166),Color(0xff07111f),Color(0xff030812)])),child:c);
  Widget header()=>Row(children:[Container(width:54,height:54,decoration:BoxDecoration(gradient:const LinearGradient(colors:[Color(0xffff9f1c),Color(0xffff4d6d)]),borderRadius:BorderRadius.circular(18)),child:const Center(child:Text('🔥',style:TextStyle(fontSize:28)))),const SizedBox(width:12),const Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('導航管家 Pro V10.1',style:TextStyle(fontSize:20,fontWeight:FontWeight.w900)),Text('哪吒AI副駕 + Waze路況導航',style:TextStyle(color:Colors.white60,fontSize:13))])),chip('BOSS',Colors.greenAccent)]);
  Widget navPage()=>shell(ListView(padding:const EdgeInsets.all(16),children:[header(),const SizedBox(height:14),hero(),const SizedBox(height:14),card(Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('Waze 真導航入口',style:TextStyle(fontSize:22,fontWeight:FontWeight.w900)),const SizedBox(height:6),const Text('預設開 Waze 取得即時路況；Google 當備用。哪吒負責測速、入口、停車、安全提醒。',style:TextStyle(color:Colors.white70)),const SizedBox(height:12),TextField(controller:quick,decoration:field('輸入目的地 / 地址 / 店名')),const SizedBox(height:10),Row(children:[Expanded(child:primary('Waze導航',()=>openNav(quick.text,Engine.waze))),const SizedBox(width:10),Expanded(child:secondary('Google備用',()=>openNav(quick.text,Engine.google)))]),const SizedBox(height:8),secondary('選擇已存地點',()=>setState(()=>tab=2))])),const SizedBox(height:14),card(Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('哪吒提醒',style:TextStyle(fontWeight:FontWeight.w900,fontSize:18)),Text(destination.isEmpty?'尚未設定目的地。':'目前目的地：$destination',style:const TextStyle(color:Colors.white70)),Text('測速：$speedCamText',style:const TextStyle(color:Colors.white70)),Text('REC：${rec?'錄影中':'未錄影'}｜GPS：${pos==null?'未定位':'已定位'}',style:const TextStyle(color:Colors.white70))]))]));
  Widget hero()=>AnimatedBuilder(animation:floatCtrl,builder:(_,__){final y=math.sin(floatCtrl.value*math.pi)*10;final warn=mood==Mood.warn||mood==Mood.angry;return Container(height:270,decoration:BoxDecoration(borderRadius:BorderRadius.circular(30),gradient:LinearGradient(colors:warn?[const Color(0x55ff4d6d),const Color(0x3307111f)]:[const Color(0x332dd4ff),const Color(0x33ff9f1c),const Color(0x227a5cff)]),border:Border.all(color:Colors.white.withOpacity(.13))),child:Stack(children:[Positioned.fill(child:CustomPaint(painter:GridPainter())),Positioned(left:35,right:35,top:145,child:Container(height:10,decoration:BoxDecoration(gradient:const LinearGradient(colors:[Color(0xffffe066),Color(0xffff9f1c),Color(0xff00d4ff)]),borderRadius:BorderRadius.circular(99),boxShadow:[BoxShadow(color:warn?Colors.redAccent:const Color(0x99ffe066),blurRadius:24)]))),const Positioned(left:45,bottom:52,child:Text('🚗',style:TextStyle(fontSize:32))),const Positioned(right:52,top:68,child:Text('📸',style:TextStyle(fontSize:30))),const Positioned(right:95,bottom:55,child:Text('🚨',style:TextStyle(fontSize:34))),Positioned(left:82,top:54+y,child:CustomPaint(size:const Size(150,150),painter:NezhaPainter())),Positioned(right:18,top:18,child:chip(rec?'🔴 REC':'REC OFF',rec?Colors.redAccent:Colors.white54)),Positioned(left:18,bottom:18,right:18,child:Container(padding:const EdgeInsets.all(12),decoration:BoxDecoration(color:Colors.black.withOpacity(.35),borderRadius:BorderRadius.circular(18)),child:Text(line('Waze帶路，我在旁邊盯測速和安全。',mood),style:const TextStyle(fontWeight:FontWeight.w700))))]));});
  Widget aiPage()=>shell(Column(children:[Padding(padding:const EdgeInsets.all(16),child:header()),Expanded(child:ListView.builder(padding:const EdgeInsets.symmetric(horizontal:16),itemCount:chat.length,itemBuilder:(_,i){final m=chat[i];final isAi=m.containsKey('ai');return Align(alignment:isAi?Alignment.centerLeft:Alignment.centerRight,child:Container(margin:const EdgeInsets.only(bottom:10),padding:const EdgeInsets.all(14),constraints:const BoxConstraints(maxWidth:330),decoration:BoxDecoration(color:isAi?Colors.orange.withOpacity(.15):Colors.blue.withOpacity(.18),borderRadius:BorderRadius.circular(18),border:Border.all(color:Colors.white.withOpacity(.10))),child:Text(isAi?'哪吒：${m['ai']}':m['user']!,style:const TextStyle(height:1.35))));})),Container(padding:const EdgeInsets.all(12),color:const Color(0xee07111f),child:Row(children:[IconButton.filled(onPressed:toggleListen,icon:Icon(listening?Icons.stop:Icons.mic)),const SizedBox(width:8),Expanded(child:TextField(controller:ai,decoration:field(listening?'我在聽...':'問哪吒：導航？測速？停車？入口？'),onSubmitted:(_)=>ask())),const SizedBox(width:8),IconButton.filled(onPressed:ask,icon:const Icon(Icons.send))]))]));
  Widget placesPage()=>shell(ListView(padding:const EdgeInsets.all(16),children:[header(),const SizedBox(height:14),const Text('已存地點',style:TextStyle(fontSize:22,fontWeight:FontWeight.w900)),const SizedBox(height:10),for(final p in places)placeCard(p)]));
  Widget placeCard(Place p)=>Container(margin:const EdgeInsets.only(bottom:12),child:card(Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Row(children:[Expanded(child:Text(p.name,style:const TextStyle(fontSize:20,fontWeight:FontWeight.w900))),if(p.done)chip('完成',Colors.greenAccent)]),const SizedBox(height:6),Text('地址：${p.address}\n入口：${p.entry.isEmpty?'未設定':p.entry}\n停車：${p.parking.isEmpty?'未設定':p.parking}\n備註：${p.note.isEmpty?'無':p.note}',style:const TextStyle(color:Colors.white70,height:1.45)),const SizedBox(height:10),Row(children:[Expanded(child:primary('Waze',()=>openNav(bestTarget(p),Engine.waze))),const SizedBox(width:8),Expanded(child:secondary('Google',()=>openNav(bestTarget(p),Engine.google))),const SizedBox(width:8),Expanded(child:secondary('完成',(){setState(()=>p.done=true);say('這站完成了。',Mood.happy);}))])]))); 
  Widget addPage()=>shell(ListView(padding:const EdgeInsets.all(16),children:[header(),const SizedBox(height:14),card(Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('新增客戶 / 常用地點',style:TextStyle(fontSize:22,fontWeight:FontWeight.w900)),const SizedBox(height:12),TextField(controller:name,decoration:field('名稱')),const SizedBox(height:10),TextField(controller:addr,decoration:field('地址')),const SizedBox(height:10),TextField(controller:entry,decoration:field('入口位置')),const SizedBox(height:10),TextField(controller:park,decoration:field('停車點')),const SizedBox(height:10),TextField(controller:note,decoration:field('備註')),const SizedBox(height:12),primary('儲存地點',savePlace)]))]));
  Widget speedPage()=>shell(ListView(padding:const EdgeInsets.all(16),children:[header(),const SizedBox(height:14),card(Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('測速照相提醒',style:TextStyle(fontSize:22,fontWeight:FontWeight.w900)),const SizedBox(height:8),Text(speedCamText,style:const TextStyle(color:Colors.orangeAccent,fontWeight:FontWeight.w800)),const SizedBox(height:8),const Text('免費版採用內建測速點資料。正式商業版可匯入完整台灣測速JSON清單。',style:TextStyle(color:Colors.white70,height:1.45))])),for(final c in cams)card(Text('${c.name}\n速限：${c.limit}\n座標：${c.lat}, ${c.lng}',style:const TextStyle(color:Colors.white70,height:1.45)))]));
  Widget safePage()=>shell(ListView(padding:const EdgeInsets.all(16),children:[header(),const SizedBox(height:14),card(Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('安全 / GPS狀態',style:TextStyle(fontSize:22,fontWeight:FontWeight.w900)),const SizedBox(height:10),lineRow('手機GPS',gpsOn?'已開':'未開',gpsOn),lineRow('定位權限',permOk?'允許':'未允許',permOk),lineRow('目前速度','${speed.toStringAsFixed(1)} km/h',speed<=75),lineRow('錄影狀態',rec?'錄影中':'未錄影',rec),const SizedBox(height:10),Text(pos==null?'尚未定位':'緯度：${pos!.latitude.toStringAsFixed(6)}\n經度：${pos!.longitude.toStringAsFixed(6)}\n精準度：${pos!.accuracy.toStringAsFixed(0)}m',style:const TextStyle(color:Colors.white70,height:1.5)),const SizedBox(height:10),primary('重新定位',startGps),const SizedBox(height:8),secondary('開啟權限設定',openAppSettings)])),const SizedBox(height:14),card(Text('震動值：${shock.toStringAsFixed(1)}\n安全/測速事件：$warnings',style:const TextStyle(color:Colors.white70,height:1.6)))]));
  Widget card(Widget child)=>Container(margin:const EdgeInsets.only(bottom:10),padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:const Color(0xbb13273e),borderRadius:BorderRadius.circular(24),border:Border.all(color:Colors.white.withOpacity(.12))),child:child);
  Widget chip(String text,Color color)=>Container(padding:const EdgeInsets.symmetric(horizontal:10,vertical:6),decoration:BoxDecoration(color:color.withOpacity(.18),borderRadius:BorderRadius.circular(99)),child:Text(text));
  Widget lineRow(String a,String b,bool ok)=>Padding(padding:const EdgeInsets.only(bottom:8),child:Row(children:[Icon(ok?Icons.check_circle:Icons.error,color:ok?Colors.greenAccent:Colors.orange),const SizedBox(width:8),Expanded(child:Text(a)),Text(b,style:TextStyle(color:ok?Colors.greenAccent:Colors.orange))]));
  InputDecoration field(String hint)=>InputDecoration(hintText:hint,filled:true,fillColor:Colors.white.withOpacity(.08),border:OutlineInputBorder(borderRadius:BorderRadius.circular(18),borderSide:BorderSide.none));
  Widget primary(String text,VoidCallback onTap)=>FilledButton(onPressed:onTap,style:FilledButton.styleFrom(padding:const EdgeInsets.symmetric(vertical:14),backgroundColor:const Color(0xffff7a1a),shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(16))),child:Text(text,style:const TextStyle(fontWeight:FontWeight.w900)));
  Widget secondary(String text,VoidCallback onTap)=>OutlinedButton(onPressed:onTap,style:OutlinedButton.styleFrom(padding:const EdgeInsets.symmetric(vertical:14),side:BorderSide(color:Colors.white.withOpacity(.18)),shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(16))),child:Text(text));
}

class NezhaPainter extends CustomPainter{
  @override void paint(Canvas canvas,Size size){final p=Paint()..isAntiAlias=true;final w=size.width,h=size.height;p.color=const Color(0xffffd7a8);canvas.drawCircle(Offset(w*.5,h*.28),w*.18,p);p.color=const Color(0xffff4d6d);canvas.drawCircle(Offset(w*.33,h*.21),w*.07,p);canvas.drawCircle(Offset(w*.67,h*.21),w*.07,p);p.color=const Color(0xffff9f1c);canvas.drawCircle(Offset(w*.23,h*.61),w*.11,p);canvas.drawCircle(Offset(w*.77,h*.61),w*.11,p);p.color=const Color(0xffd62828);final body=Path()..moveTo(w*.5,h*.43)..lineTo(w*.28,h*.82)..lineTo(w*.72,h*.82)..close();canvas.drawPath(body,p);p.color=const Color(0xffffe066);p.strokeWidth=6;p.strokeCap=StrokeCap.round;canvas.drawLine(Offset(w*.2,h*.48),Offset(w*.84,h*.78),p);p.color=Colors.black;p.style=PaintingStyle.fill;canvas.drawCircle(Offset(w*.43,h*.28),3,p);canvas.drawCircle(Offset(w*.57,h*.28),3,p);p.strokeWidth=2;p.style=PaintingStyle.stroke;canvas.drawArc(Rect.fromCenter(center:Offset(w*.5,h*.34),width:26,height:15),0,math.pi,false,p);p.style=PaintingStyle.fill;p.color=Colors.white.withOpacity(.9);canvas.drawCircle(Offset(w*.23,h*.61),w*.045,p);canvas.drawCircle(Offset(w*.77,h*.61),w*.045,p);}
  @override bool shouldRepaint(covariant CustomPainter oldDelegate)=>false;
}
class GridPainter extends CustomPainter{ @override void paint(Canvas canvas,Size size){final p=Paint()..color=Colors.white.withOpacity(.055)..strokeWidth=1;for(double x=-80;x<size.width+120;x+=42){canvas.drawLine(Offset(x,size.height),Offset(x+140,0),p);}for(double y=0;y<size.height+80;y+=42){canvas.drawLine(Offset(0,y),Offset(size.width,y-80),p);}} @override bool shouldRepaint(covariant CustomPainter oldDelegate)=>false;}
