import Foundation
import Darwin
import CryptoKit
import ImageIO
import MLX
import VoxamberShapeNative

let inputPath = "/Users/kaisun/Three-Live/docs/qa/2026-11-06-native-image-vase/reference-prepared-512-rgba.png"
let packPath = "/Users/kaisun/Three-Live/Apple/.build/NeuralModels/Shape21Q4/model.q4.safetensors"
let inputSHA = "1bcadef55c9795d68cbce576cf57eabd7d6b7b87a22ba048c6fba8f7ca6521ae"
let clock = ContinuousClock()
func seconds(_ a: ContinuousClock.Instant, _ b: ContinuousClock.Instant) -> Double {
    let v = a.duration(to:b).components
    return Double(v.seconds) + Double(v.attoseconds)/1e18
}
func digest(_ data:Data)->String { SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined() }
func fileDigest(_ url:URL)throws->String {
    let h=try FileHandle(forReadingFrom:url);defer{try? h.close()};var sha=SHA256()
    var done=false
    while !done {try autoreleasepool {let d=try h.read(upToCount:1_048_576) ?? Data();if d.isEmpty{done=true}else{sha.update(data:d)}}}
    return sha.finalize().map{String(format:"%02x",$0)}.joined()
}
func physical()->UInt64? {
    var info=task_vm_info_data_t(),count=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size)
    let r=withUnsafeMutablePointer(to:&info){$0.withMemoryRebound(to:integer_t.self,capacity:Int(count)){task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count)}}
    return r==KERN_SUCCESS ? info.phys_footprint : nil
}
func preflight()throws->(Data,String) {
    let png=try Data(contentsOf:URL(fileURLWithPath:inputPath))
    guard png.count==249722,digest(png)==inputSHA,
          let source=CGImageSourceCreateWithData(png as CFData,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil),
          image.width==512,image.height==512 else {throw CocoaError(.fileReadCorruptFile)}
    let pack=URL(fileURLWithPath:packPath),profile=HunyuanShape21WeightProfile.rebuiltQ4Candidate
    let values=try pack.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
    guard values.isRegularFile==true,values.isSymbolicLink != true,Int64(values.fileSize ?? 0)==profile.modelPackBytes,
          try fileDigest(pack)==profile.modelPackSHA256 else {throw CocoaError(.fileReadCorruptFile)}
    let yaml=try HunyuanShape21Configuration.bundledYAML
    guard digest(Data(yaml.utf8)) == HunyuanShape21Configuration.configurationSHA256 else { throw CocoaError(.fileReadCorruptFile) }
    return (png,yaml)
}
final class RequestOwner:@unchecked Sendable {
    private let lock=NSLock();private var work:Task<ShapeResult,Error>?;private var delayed:Task<Void,Never>?
    private var cancelled=false,closed=false
    func assign(_ t:Task<ShapeResult,Error>){lock.lock();work=t;let c=cancelled;lock.unlock();if c{t.cancel()}}
    func cancel(){lock.lock();cancelled=true;let t=work;lock.unlock();t?.cancel()}
    func schedule(_ make:()->Task<Void,Never>){lock.lock();defer{lock.unlock()};guard delayed==nil,!closed else{return};delayed=make()}
    func settleDelay()async{let t=lock.withLock{closed=true;return delayed};t?.cancel();await t?.value}
    func release(){lock.withLock{work=nil;delayed=nil}}
}
final class ReportStore:@unchecked Sendable {
    private let lock=NSLock();private var value:[String:Any];let url:URL
    init(_ output:URL){url=output.appending(path:"cancellation-report.json");value=["schemaVersion":1,"status":"running","publicAPIOnly":true,"learnedModelRequestsMaximum":1,"publicCallsMaximum":2,"retries":0,"publishedModelArtifacts":0,"platform":"host Mac, not phone","privateChunkCheckpointObserved":false,"watchdogSeconds":900,"watchdogIsHardPreemption":false,"stopObservationThresholdSeconds":5]}
    func put(_ key:String,_ item:Any)throws {try lock.withLock{value[key]=item;try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.prettyPrinted]).write(to:url,options:.atomic)}}
}
final class TrialState:@unchecked Sendable {
    let began=clock.now,owner:RequestOwner,kind:String
    private let lock=NSLock();private var firstStep:ContinuousClock.Instant?,request:ContinuousClock.Instant?
    private var reason:String?,events=[[String:Any]](),peak:UInt64=0,samples=0,verifying=false,loading=false,denoising=false,watchdog=false,ioFailure=false
    init(kind:String,owner:RequestOwner){self.kind=kind;self.owner=owner}
    func progress(_ p:ShapeProgress)->ContinuousClock.Instant? {lock.lock();defer{lock.unlock()}
        let now=clock.now;events.append(["stage":p.stage,"seconds":seconds(began,now)])
        if p.stage=="Verifying shape model"{verifying=true}
        if p.stage=="Loading shape model"{loading=true}
        if p.stage.hasPrefix("Denoising ("){denoising=true}
        if p.stage=="Denoising (1/10)",firstStep==nil {firstStep=now;return now}
        return nil
    }
    func recordRequest(_ why:String){lock.withLock{if request==nil{request=clock.now;reason=why};if why=="watchdog"{watchdog=true}};owner.cancel()}
    func sample(){guard let n=physical()else{return};lock.withLock{peak=max(peak,n);samples+=1}}
    func failIO(){lock.withLock{ioFailure=true};recordRequest("telemetryIO")}
    func snapshot(returned:ContinuousClock.Instant?=nil,idle:ContinuousClock.Instant?=nil)->[String:Any]{lock.lock();defer{lock.unlock()}
        var d:[String:Any]=["kind":kind,"events":events,"verifyingObserved":verifying,"loadingObserved":loading,"denoisingObserved":denoising,"watchdogTriggered":watchdog,"telemetryIOFailure":ioFailure,"physicalPeakObservedBytes":peak,"physicalSampleCount":samples,"nominalSampleIntervalSeconds":0.2]
        if let firstStep{d["firstDenoiseStepSeconds"]=seconds(began,firstStep)}
        if let request{d["cancelRequestSeconds"]=seconds(began,request);d["cancelReason"]=reason
            if let firstStep{d["firstStepToRequestSeconds"]=seconds(firstStep,request)}
            if let returned{d["requestToPublicGenerateReturnSeconds"]=seconds(request,returned)}
            if let idle{d["requestToUnloadIdleSeconds"]=seconds(request,idle)}
        }
        return d
    }
}
func runTrial(kind:String,png:Data,yaml:String,store:ReportStore,watchDeadline:ContinuousClock.Instant)async throws->Bool {
    let owner=RequestOwner(),state=TrialState(kind:kind,owner:owner),engine=ShapeEngine(weightProfile:.rebuiltQ4Candidate)
    let sampler=Task.detached{while !Task.isCancelled{state.sample();try?await Task.sleep(for:.milliseconds(200))}}
    let work=Task {try await engine.generate(pngData:png,shapePackURL:URL(fileURLWithPath:packPath),configurationYAML:yaml,seed:24301,onProgress:{p in
        let step=state.progress(p)
        if kind=="leaseProbe",p.stage=="Verifying shape model" {state.recordRequest("firstVerifyingCallback")}
        if kind=="first",let step {owner.schedule{
            Task.detached {
                do{try await clock.sleep(until:step.advanced(by:.milliseconds(500)))}catch{return}
                guard !Task.isCancelled else{return}
                state.recordRequest("firstDenoiseStepPlus500ms")
                do{try store.put(kind,state.snapshot())}catch{state.failIO()}
                await engine.cancel()
            }
        }}
        do{try store.put(kind,state.snapshot())}catch{state.failIO()}
    })}
    owner.assign(work)
    let watchdog=Task.detached{do{try await clock.sleep(until:watchDeadline)}catch{return};guard !Task.isCancelled else{return};state.recordRequest("watchdog");do{try store.put(kind,state.snapshot())}catch{state.failIO()};await engine.cancel()}
    var cancellation=false,unexpectedSuccess=false,busyObserved=false,errorType:String?
    do{_ = try await withTaskCancellationHandler{try await work.value}onCancel:{state.recordRequest("callerCancellation")};unexpectedSuccess=true}
    catch is CancellationError{cancellation=true}
    catch ShapeError.busy{busyObserved=true;errorType="ShapeError.busy"}
    catch{errorType=String(reflecting:type(of:error))}
    let returned=clock.now
    watchdog.cancel();await watchdog.value
    await owner.settleDelay()
    let statusBeforeUnload=await engine.status
    await engine.cancel();await engine.unload()
    let idleAt=clock.now,status=await engine.status
    state.sample();sampler.cancel();await sampler.value
    var result=state.snapshot(returned:returned,idle:idleAt)
    result["publicGenerateReturnedCancellationError"]=cancellation;result["unexpectedResultReturned"]=unexpectedSuccess;result["busyObserved"]=busyObserved
    if let errorType{result["otherErrorType"]=errorType}
    result["publicStatusBeforeUnload"]=statusBeforeUnload.rawValue;result["publicStatusAfterUnload"]=status.rawValue
    if let bytes=physical(){result["physicalBytesAfterUnload"]=bytes}
    // Reading allocator residue only after a real Loading stage (or the second
    // probe after first succeeded) avoids initializing MLX in --arm/pre-cancel.
    if result["loadingObserved"] as? Bool==true || kind=="leaseProbe" {
        let m=Memory.snapshot();result["mlxAfterUnload"]=["activeBytes":m.activeMemory,"cacheBytes":m.cacheMemory,"processPeakBytes":m.peakMemory]
    }
    let noFailure=(result["watchdogTriggered"] as? Bool==false && result["telemetryIOFailure"] as? Bool==false)
    let firstContract=kind=="first" && result["firstDenoiseStepSeconds"] != nil
        && result["cancelReason"] as? String=="firstDenoiseStepPlus500ms"
    let probeContract=kind=="leaseProbe" && result["verifyingObserved"] as? Bool==true
        && result["loadingObserved"] as? Bool==false && result["denoisingObserved"] as? Bool==false
        && result["cancelReason"] as? String=="firstVerifyingCallback"
    let latency=result["requestToUnloadIdleSeconds"] as? Double
    let macBelow5=latency.map{$0<5} ?? false
    let passed=cancellation && !unexpectedSuccess && errorType==nil && status == .idle && noFailure && (firstContract || probeContract) && macBelow5
    result["macStopObservedBelow5Seconds"]=macBelow5;result["contractPassed"]=passed
    owner.release()
    try store.put(kind,result)
    return passed
}
@main enum Main {
    static func main()async {
        do {
            let args=Array(CommandLine.arguments.dropFirst())
            guard args==["--arm"] || (args.count==2 && args[0]=="--run") else {throw CocoaError(.fileReadInvalidFileName)}
            let (png,yaml)=try preflight()
            if args==["--arm"] {print("ARMED: exact PNG/model/YAML CPU SHA preflight PASS; no public model call or MLX memory query");return}
            let output=URL(fileURLWithPath:args[1]);guard !FileManager.default.fileExists(atPath:output.path)else{throw CocoaError(.fileWriteFileExists)}
            FileHandle.standardOutput.write(Data("ARMED: waiting for exact RUN line; no neural call yet\n".utf8))
            guard readLine()=="RUN"else{throw CocoaError(.userCancelled)}
            try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
            let store=ReportStore(output)
            let watchDeadline=clock.now.advanced(by:.seconds(900))
            try store.put("fixedSettings",["inputSHA256":inputSHA,"modelPackSHA256":HunyuanShape21WeightProfile.rebuiltQ4Candidate.modelPackSHA256,"configurationSHA256":HunyuanShape21Configuration.configurationSHA256,"profile":HunyuanShape21WeightProfile.rebuiltQ4Candidate.rawValue,"geometryPostprocessID":HunyuanShape21WeightProfile.rebuiltQ4Candidate.geometryPostprocessID,"seed":24301,"steps":10,"guidance":5,"latents":4096,"octreeResolution":192,"moeTokenChunkSize":512,"serializedCFG":true,"cancelDelayMilliseconds":500])
            let first=try await runTrial(kind:"first",png:png,yaml:yaml,store:store,watchDeadline:watchDeadline)
            var probe=false
            if first{probe=try await runTrial(kind:"leaseProbe",png:png,yaml:yaml,store:store,watchDeadline:watchDeadline)}
            let pinsStable=try fileDigest(URL(fileURLWithPath:packPath))==HunyuanShape21WeightProfile.rebuiltQ4Candidate.modelPackSHA256
                && digest(Data(contentsOf:URL(fileURLWithPath:inputPath)))==inputSHA
            try store.put("pinsStableAfter",pinsStable)
            try store.put("learnedModelRequestCount",1)
            try store.put("publicCallCount",first ? 2:1)
            try store.put("noRunnerPublishedGLBorUSDZ",true)
            try store.put("status",first && probe && pinsStable ? "publicCancellationAndNoNNLeaseProbePassed":"failed_no_retry")
            print(first && probe && pinsStable ? "PUBLIC CANCEL GATE PASS (Mac only)":"PUBLIC CANCEL GATE FAILED (no retry)")
            if !first || !probe || !pinsStable{exit(1)}
        } catch {print("GATE FAILED: "+String(reflecting:type(of:error)));exit(1)}
    }
}
