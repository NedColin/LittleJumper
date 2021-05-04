//
//  ViewController.m
//  LittleJumper
//
//  Created by anjohnlv on 2018/1/22.
//  Copyright © 2018年 anjohnlv. All rights reserved.
//

#import "ViewController.h"
#import <SceneKit/SceneKit.h>
#import "MetalTypes.h"

@implementation NSObject (Util)

- (NSArray *)createPipeLineState:(id <MTLDevice>)device{
    
    id <MTLLibrary> library = [device newDefaultLibrary];
    id <MTLFunction> vertexFunction = [library newFunctionWithName:@"vertexVideoShader"];
    id <MTLFunction> fragmentFunction = [library newFunctionWithName:@"fragmentVideoShader"];
    
    MTLRenderPipelineDescriptor * renderPipeDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    
    renderPipeDescriptor.vertexFunction = vertexFunction;
    renderPipeDescriptor.fragmentFunction = fragmentFunction;
    //必须和scnview的匹配
    renderPipeDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    renderPipeDescriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    
    NSError * error = nil;
    
    id <MTLRenderPipelineState> renderPipelineState = [device newRenderPipelineStateWithDescriptor:renderPipeDescriptor error:&error];

    id <MTLCommandQueue> commondQueue = [device newCommandQueue];
    
    return @[renderPipelineState, commondQueue];
}

@end


static const double kMaxPressDuration = 2.f;
static const int kMaxPlatformRadius = 6;
static const int kMinPlatformRadius = kMaxPlatformRadius-4;
static const double kGravityValue = 30;

typedef NS_OPTIONS(NSUInteger, CollisionDetectionMask) {
    CollisionDetectionMaskNone = 0,
    CollisionDetectionMaskFloor = 1 << 0,
    CollisionDetectionMaskPlatform = 1 << 1,
    CollisionDetectionMaskJumper = 1 << 2,
    CollisionDetectionMaskOldPlatform = 1 << 3,
};

@interface ViewController ()<SCNPhysicsContactDelegate, UIGestureRecognizerDelegate, SCNSceneRendererDelegate>
@property (strong, nonatomic) IBOutlet UIControl *infoView;
@property (strong, nonatomic) IBOutlet UILabel *scoreLabel;
- (IBAction)restart;

@property(nonatomic, strong)SCNView *scnView;
@property(nonatomic, strong)SCNScene *scene;
@property(nonatomic, strong)SCNNode *floor;
@property(nonatomic, strong)SCNNode *lastPlatform, *platform, *nextPlatform;
@property(nonatomic, strong)SCNNode *jumper;
@property(nonatomic, strong)SCNNode *camera,*light;
@property(nonatomic, strong)NSDate *pressDate;
@property(nonatomic, strong)SCNRenderer *render;
@property(nonatomic)NSInteger score;

#pragma mark - metal

@property(nonatomic, strong)id<MTLCommandQueue> commandQueue;
@property(nonatomic, strong)id<MTLRenderPipelineState> renderPipelineState;

@property (nonatomic, strong) id <MTLBuffer> vertexBuffer;
@property (nonatomic, strong) id <MTLBuffer> convertMatrix;
@property (nonatomic, strong) id <MTLTexture> texture;
@property (nonatomic, assign) NSUInteger vertexCount;

@property (atomic, assign) CVPixelBufferRef pixelBuffer;
@property (nonatomic, assign) CVMetalTextureCacheRef textureCache;
@property (atomic, strong) id <MTLTexture> textureY;
@property (atomic, strong) id <MTLTexture> textureUV;

@property (atomic, assign) CGSize scnViewSize;

@property (atomic, strong) id <MTLComputePipelineState> computePipielineSate;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    if(self.scnView && self.floor && self.jumper) {
        [self createFirstPlatform];
        [self setupVertexsWithWidthScaling:1.0f heightScaling:1.0f];
        [self setupMatrix];
        [self initMetal];
        [self initRender];
        UIImage * img = [UIImage imageNamed:@"robot"];
        CVPixelBufferRef pixelBufRef = [self pixelBufferFromCGImage:img.CGImage];
        if (pixelBufRef) {
            [self setupTextureWithPixelBuffer:pixelBufRef];
        }
    }
}

- (void)viewDidLayoutSubviews{
    [super viewDidLayoutSubviews];
    if (CGSizeEqualToSize(self.scnViewSize, CGSizeZero)) {
        self.scnViewSize = self.scnView.frame.size;
    }
}

- (void)initMetal{
    self.scnView.delegate = self;
    NSArray * output = [self createPipeLineState:self.scnView.device];
    self.renderPipelineState = output[0];
    self.commandQueue = output[1];
    CVMetalTextureCacheCreate(NULL, NULL, [self device], NULL, &_textureCache);
    
    id <MTLLibrary> library = [[self device] newDefaultLibrary];
    id <MTLFunction> kernelFunction = [library newFunctionWithName:@"rgb2hsvKernelNonuniform"];
    NSError * cmpPiplineInstanceErr = nil;
    self.computePipielineSate = [[self device] newComputePipelineStateWithFunction:kernelFunction error:&cmpPiplineInstanceErr];
    assert(!cmpPiplineInstanceErr);
    
}

- (void)initRender{
    
    if (self.scnView.device) {
        self.render = [SCNRenderer rendererWithDevice:[self device] options:nil];
        self.render.scene = self.scnView.scene;
        self.render.delegate = self;
        self.render.pointOfView = self.scnView.scene.rootNode;
        NSLog(@"initRender:%@", self.render);
    }
}

- (id<MTLDevice>)device{
    return self.scnView.device;
}

// 生成Y纹理和UV纹理，提供给MTKView的代理方法使用
- (void)setupTextureWithPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer) {
        return;
    }
    
    if (CVPixelBufferGetPixelFormatType(pixelBuffer) == MTLPixelFormatRG8Snorm) {
        //rgb
        size_t width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0);
        size_t height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0);
        
        // 像素颜色格式 MTLPixelFormatR8Unorm 表示只取R一个颜色分支
        MTLPixelFormat pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);

        CVMetalTextureRef texture = NULL;
        CVMetalTextureCacheRef textureCache = NULL;
        
        // 开辟纹理缓存区
        CVReturn TextureCacheCreateStatus =CVMetalTextureCacheCreate(NULL, NULL, self.device, NULL, &textureCache);
        if(TextureCacheCreateStatus == kCVReturnSuccess) {
            NSLog(@"CVMetalTextureCacheCreate is success");
        }
        
        // 根据CVPixelBufferRef数据，使用CVMetalTextureCacheRef，创建CVMetalTextureRef
        // 0表示Y纹理
        CVReturn status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, self.textureCache, pixelBuffer, NULL, pixelFormat, width, height, 0, &texture);
        if(status == kCVReturnSuccess) {
            // 根据纹理CVMetalTextureRef 创建id <MTLTexture>
            self.textureY = CVMetalTextureGetTexture(texture);
            
            // 使用完毕释放资源
            CFRelease(texture);
            
            NSLog(@"create Y texture is Success");
        } else {
            NSLog(@"create Y texture is failed");
            NSLog(@"status == %d", status);
        }
        CFRelease(textureCache);
        return;
    }
    
    // Y纹理
    {
        // 0表示Y纹理
        size_t width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0);
        size_t height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0);
        
        
        // 像素颜色格式 MTLPixelFormatR8Unorm 表示只取R一个颜色分支
        MTLPixelFormat pixelFormat = MTLPixelFormatR8Unorm;

        CVMetalTextureRef texture = NULL;
        CVMetalTextureCacheRef textureCache = NULL;
        
        // 开辟纹理缓存区
        CVReturn TextureCacheCreateStatus =CVMetalTextureCacheCreate(NULL, NULL, self.device, NULL, &textureCache);
        if(TextureCacheCreateStatus == kCVReturnSuccess) {
//            NSLog(@"CVMetalTextureCacheCreate is success");
        }
        
        // 根据CVPixelBufferRef数据，使用CVMetalTextureCacheRef，创建CVMetalTextureRef
        // 0表示Y纹理
        CVReturn status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, self.textureCache, pixelBuffer, NULL, pixelFormat, width, height, 0, &texture);
        if(status == kCVReturnSuccess) {
            // 根据纹理CVMetalTextureRef 创建id <MTLTexture>
            self.textureY = CVMetalTextureGetTexture(texture);
            
            // 使用完毕释放资源
            CFRelease(texture);
            
//            NSLog(@"create Y texture is Success");
        } else {
//            NSLog(@"create Y texture is failed");
//            NSLog(@"status == %d", status);
        }
        CFRelease(textureCache);
    }
    
    // UV纹理
    {
        // 1表示UV纹理
        size_t width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1);
        size_t height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1);
        
        // 像素颜色格式 MTLPixelFormatRG8Unorm 表示只取RG两个颜色分支
        MTLPixelFormat pixelFormat = MTLPixelFormatRG8Unorm;
        
        CVMetalTextureRef texture = NULL;
        CVMetalTextureCacheRef textureCache = NULL;
        // 开辟纹理缓存区
        CVReturn TextureCacheCreateStatus =CVMetalTextureCacheCreate(NULL, NULL, self.device, NULL, &textureCache);
        if(TextureCacheCreateStatus == kCVReturnSuccess) {
//            NSLog(@"CVMetalTextureCacheCreate is success");
        }
        
        // 根据CVPixelBufferRef数据，使用CVMetalTextureCacheRef，创建CVMetalTextureRef
        // 1表示UV纹理
        
        CVReturn status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, self.textureCache, pixelBuffer, NULL, pixelFormat, width, height, 1, &texture);
        if(status == kCVReturnSuccess) {
            // 根据纹理CVMetalTextureRef 创建id <MTLTexture>
            self.textureUV = CVMetalTextureGetTexture(texture);
            
            // 使用完毕释放资源
            CFRelease(texture);
            
//            NSLog(@"create UV texture is Success");
        } else {
//            NSLog(@"create UV texture is failed");
//            NSLog(@"status == %d", status);
        }
        
        CFRelease(textureCache);
    }
}

- (CVPixelBufferRef) pixelBufferFromCGImage: (CGImageRef) image
{
    NSDictionary *options = @{
                              (NSString*)kCVPixelBufferCGImageCompatibilityKey : @YES,
                              (NSString*)kCVPixelBufferCGBitmapContextCompatibilityKey : @YES,
                              (id) kCVPixelBufferMetalCompatibilityKey: @(TRUE),
                              (id) kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
                              };

    CVPixelBufferRef pxbuffer = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, CGImageGetWidth(image),
                        CGImageGetHeight(image), kCVPixelFormatType_32ARGB, (__bridge CFDictionaryRef) options,
                        &pxbuffer);
    if (status!=kCVReturnSuccess) {
        NSLog(@"Operation failed");
    }
    NSParameterAssert(status == kCVReturnSuccess && pxbuffer != NULL);

    CVPixelBufferLockBaseAddress(pxbuffer, 0);
    void *pxdata = CVPixelBufferGetBaseAddress(pxbuffer);

    CGColorSpaceRef rgbColorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pxdata, CGImageGetWidth(image),
                                                 CGImageGetHeight(image), 8, 4*CGImageGetWidth(image), rgbColorSpace,
                                                 kCGImageAlphaNoneSkipFirst);
    NSParameterAssert(context);

    CGContextConcatCTM(context, CGAffineTransformMakeRotation(0));
    CGAffineTransform flipVertical = CGAffineTransformMake( 1, 0, 0, -1, 0, CGImageGetHeight(image) );
    CGContextConcatCTM(context, flipVertical);
    CGAffineTransform flipHorizontal = CGAffineTransformMake( -1.0, 0.0, 0.0, 1.0, CGImageGetWidth(image), 0.0 );
    CGContextConcatCTM(context, flipHorizontal);

    CGContextDrawImage(context, CGRectMake(0, 0, CGImageGetWidth(image),
                                           CGImageGetHeight(image)), image);
    CGColorSpaceRelease(rgbColorSpace);
    CGContextRelease(context);

    CVPixelBufferUnlockBaseAddress(pxbuffer, 0);
    return pxbuffer;
}


// 设置YUV->RGB转换的矩阵
- (void)setupMatrix {
    
    //1.转化矩阵
    // BT.601, which is the standard for SDTV.
    matrix_float3x3 kColorConversion601DefaultMatrix = (matrix_float3x3){
        (simd_float3){1.164,  1.164, 1.164},
        (simd_float3){0.0, -0.392, 2.017},
        (simd_float3){1.596, -0.813,   0.0},
    };
    
    // BT.601 full range
    matrix_float3x3 kColorConversion601FullRangeMatrix = (matrix_float3x3){
        (simd_float3){1.0,    1.0,    1.0},
        (simd_float3){0.0,    -0.343, 1.765},
        (simd_float3){1.4,    -0.711, 0.0},
    };
    
    // BT.709, which is the standard for HDTV.
    matrix_float3x3 kColorConversion709DefaultMatrix = (matrix_float3x3){
        (simd_float3){1.164,  1.164, 1.164},
        (simd_float3){0.0, -0.213, 2.112},
        (simd_float3){1.793, -0.533,   0.0},
    };
    
    //2.偏移量
    vector_float3 kColorConversion601FullRangeOffset = (vector_float3){ -(16.0/255.0), -0.5, -0.5};
    
    //3.创建转化矩阵结构体.
    YYVideoYUVToRGBConvertMatrix matrix;
    //设置转化矩阵
    /*
     kColorConversion601DefaultMatrix；
     kColorConversion601FullRangeMatrix；
     kColorConversion709DefaultMatrix；
     */
    matrix.matrix = kColorConversion601FullRangeMatrix;
    //设置offset偏移量
    matrix.offset = kColorConversion601FullRangeOffset;
    
    //4.创建转换矩阵缓存区.
    self.convertMatrix = [[self device] newBufferWithBytes:&matrix length:sizeof(YYVideoYUVToRGBConvertMatrix) options:MTLResourceStorageModeShared];
}

- (void)setupVertexsWithWidthScaling:(CGFloat)widthScaling heightScaling:(CGFloat)heightScaling {
    // 1.顶点纹理数组
    // 顶点x,y,z,w  纹理x,y
    // 因为图片和视频的默认纹理是反的 左上 00 右上10 左下 01 右下11
    // // 左下 右下
    YYVideoVertex vertexArray[] = {
        {{-1.0 * widthScaling, -1.0 * heightScaling, 0.0, 1.0}, {0.0, 1.0}},
        {{1.0 * widthScaling, -1.0 * heightScaling, 0.0, 1.0}, {1.0, 1.0}},
        {{-1.0 * widthScaling, 1.0 * heightScaling, 0.0, 1.0}, {0.0, 0.0}}, //左上
        {{1.0 * widthScaling, 1.0 * heightScaling, 0.0, 1.0}, {1.0, 0.0}}, // 右上
    };
    
    // 2.生成顶点缓存
    // MTLResourceStorageModeShared 属性可共享的，表示可以被顶点或者片元函数或者其他函数使用
    self.vertexBuffer = [self.device newBufferWithBytes:vertexArray length:sizeof(vertexArray) options:MTLResourceStorageModeShared];
    
    // 3.获取顶点数量
    self.vertexCount = sizeof(vertexArray) / sizeof(YYVideoVertex);
}

- (void)viewDidAppear:(BOOL)animated{
    [super viewDidAppear:animated];
}

#pragma mark 添加第一个台子
/**
 初始化第一个台子
 
 @discussion 第一个台子造型固定，静态，会与小人碰撞，初始化完成后调整镜头位置
 */
-(void)createFirstPlatform {
    
    self.platform = ({
        SCNNode *node = [SCNNode node];
        node.geometry = ({
            SCNCylinder *cylinder = [SCNCylinder cylinderWithRadius:5 height:2];
            cylinder.firstMaterial.diffuse.contents = UIColor.redColor;
            cylinder;
        });
        node.physicsBody = ({
            SCNPhysicsBody *body = [SCNPhysicsBody staticBody];
            body.restitution = 0.9;
            body.friction = 1;
            body.damping = 0;
            body.categoryBitMask = CollisionDetectionMaskPlatform;
            body.collisionBitMask = CollisionDetectionMaskJumper|CollisionDetectionMaskPlatform|CollisionDetectionMaskOldPlatform;
            body;
        });
        node.position = SCNVector3Make(0, 0, 0);
        [self.scene.rootNode addChildNode:node];
        node;
    });
    [self moveCameraToCurrentPlatform];
}

#pragma mark 蓄力
/**
 长按手势事件
 
 @discussion 通过长按时间差模拟力量，如果有最大值
 */
-(void)accumulateStrength:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        _pressDate = [NSDate date];
        [self updateStrengthStatus];
    }else if(recognizer.state == UIGestureRecognizerStateEnded) {
        if (_pressDate) {
            self.jumper.geometry.firstMaterial.diffuse.contents = UIColor.whiteColor;
            [self.jumper removeAllActions];
            NSDate *now = [NSDate date];
            double pressDate = [_pressDate timeIntervalSince1970];
            double nowDate = [now timeIntervalSince1970];
            double power = nowDate - pressDate;
            power = power>kMaxPressDuration?kMaxPressDuration:power;
            [self jumpWithPower:power];
            _pressDate = nil;
        }
    }
}

/**
 力量显示
 
 @discussion 这里简单地用颜色表示，力量越大，小人越红
 */
-(void)updateStrengthStatus {
    SCNAction *action = [SCNAction customActionWithDuration:kMaxPressDuration actionBlock:^(SCNNode * node, CGFloat elapsedTime) {
        CGFloat percentage = elapsedTime/kMaxPressDuration;
        self.jumper.geometry.firstMaterial.diffuse.contents = [UIColor colorWithRed:1 green:1-percentage blue:1-percentage alpha:1];
    }];
    [self.jumper runAction:action];
}

#pragma mark 发力
/**
 根据力量值给小人一个力

 @param power 按的时间0~kMaxPressDuration秒
 @discussion 根据按的时间长短，对小人施加一个力，力由一个向上的力，和平面方向上的力组成，平面方向的力由小人的位置和目标台子的位置计算得出
 */
-(void)jumpWithPower:(double)power {
    power *= 30;
    SCNVector3 platformPosition = self.nextPlatform.presentationNode.position;
    SCNVector3 jumperPosition = self.jumper.presentationNode.position;
    double subtractionX = platformPosition.x-jumperPosition.x;
    double subtractionZ = platformPosition.z-jumperPosition.z;
    double proportion = fabs(subtractionX/subtractionZ);
    double x = sqrt(1 / (pow(proportion, 2) + 1)) * proportion;
    double z = sqrt(1 / (pow(proportion, 2) + 1));
    x*=subtractionX<0?-1:1;
    z*=subtractionZ<0?-1:1;
    SCNVector3 force = SCNVector3Make(x*power, 20, z*power);
    [self.jumper.physicsBody applyForce:force impulse:YES];
}

#pragma mark 跳跃会触发的事件
-(void)jumpCompleted {
    self.score++;
    self.lastPlatform = self.platform;
    self.platform = self.nextPlatform;
    [self moveCameraToCurrentPlatform];
}

/**
 调整镜头以观察小人目前所在台子的位置
 */
-(void)moveCameraToCurrentPlatform {
    SCNVector3 position = self.platform.presentationNode.position;
    position.x += 20;
    position.y += 30;
    position.z += 20;
    SCNAction *move = [SCNAction moveTo:position duration:0.5];
    [self.camera runAction:move];
    [self createNextPlatform];
}

/**
 创建下一个台子
 */
-(void)createNextPlatform {
    self.nextPlatform = ({
        SCNNode *node = [SCNNode node];
        node.geometry = ({
            //随机大小
            int radius = (arc4random() % kMinPlatformRadius) + (kMaxPlatformRadius-kMinPlatformRadius);
            SCNCylinder *cylinder = [SCNCylinder cylinderWithRadius:radius height:2];
            //随机颜色
            cylinder.firstMaterial.diffuse.contents = ({
                CGFloat r = ((arc4random() % 255)+0.0)/255;
                CGFloat g = ((arc4random() % 255)+0.0)/255;
                CGFloat b = ((arc4random() % 255)+0.0)/255;
                UIColor *color = [UIColor colorWithRed:r green:g blue:b alpha:1];
                color;
            });
            cylinder;
        });
        node.physicsBody = ({
            SCNPhysicsBody *body = [SCNPhysicsBody dynamicBody];
//            body.mass = 100;
            body.restitution = 1;
            body.friction = 1;
            body.damping = 0;
            body.allowsResting = YES;
            body.categoryBitMask = CollisionDetectionMaskPlatform;
            body.collisionBitMask = CollisionDetectionMaskJumper|CollisionDetectionMaskFloor|CollisionDetectionMaskOldPlatform|CollisionDetectionMaskPlatform;
            body.contactTestBitMask = CollisionDetectionMaskJumper;
            body;
        });
        //随机位置
        node.position = ({
            SCNVector3 position = self.platform.presentationNode.position;
            int xDistance = (arc4random() % (kMaxPlatformRadius*3-1))+1;
            position.z -= ({
                double lastRadius = ((SCNCylinder *)self.platform.geometry).radius;
                double radius = ((SCNCylinder *)node.geometry).radius;
                double maxDistance = sqrt(pow(kMaxPlatformRadius*3, 2)-pow(xDistance, 2));
                double minDistance = (xDistance>lastRadius+radius)?xDistance:sqrt(pow(lastRadius+radius, 2)-pow(xDistance, 2));
                double zDistance = (((double) rand() / RAND_MAX) * (maxDistance-minDistance)) + minDistance;
                zDistance;
            });
            position.x -= xDistance;
            position.y += 5;
            position;
        });
        [self.scene.rootNode addChildNode:node];
        node;
    });
}

#pragma mark 游戏结束
-(void)gameDidOver {
    NSLog(@"Game Over");
    [self.view bringSubviewToFront:self.infoView];
    [self.scoreLabel setText:[NSString stringWithFormat:@"当前分数:%d",(int)self.score]];
}

#pragma mark SCNPhysicsContactDelegate
/**
 碰撞事件监听

 @discussion 如果是小人与地板碰撞，游戏结束。取消地板对小人的监听。
             如果是小人与台子碰撞，则跳跃完成，进行状态刷新
 */
- (void)physicsWorld:(SCNPhysicsWorld *)world didBeginContact:(SCNPhysicsContact *)contact{
    SCNPhysicsBody *bodyA = contact.nodeA.physicsBody;
    SCNPhysicsBody *bodyB = contact.nodeB.physicsBody;
    if (bodyA.categoryBitMask==CollisionDetectionMaskJumper) {
        if (bodyB.categoryBitMask==CollisionDetectionMaskFloor) {
            bodyB.contactTestBitMask = CollisionDetectionMaskNone;
            [self performSelectorOnMainThread:@selector(gameDidOver) withObject:nil waitUntilDone:NO];
        }else if (bodyB.categoryBitMask==CollisionDetectionMaskPlatform) {
            //这里有个小bug，我在第一次收到碰撞后进行如下配置，按理说不应该收到碰撞回调了。可实际上还是会来。于是我直接将跳过的台子的categoryBitMask改为CollisionDetectionMaskOldPlatform，保证每个台子只会收到一次。上面的掉落又没有这个bug。
            //bodyB.contactTestBitMask = CollisionDetectionMaskNone;
            bodyB.categoryBitMask = CollisionDetectionMaskOldPlatform;
            [self jumpCompleted];
        }
    }
}

#pragma mark 懒加载
-(SCNScene *)scene {
    if (!_scene) {
        _scene = ({
            SCNScene *scene = [SCNScene new];
            scene.physicsWorld.contactDelegate = self;
            scene.physicsWorld.gravity = SCNVector3Make(0, -kGravityValue, 0);
            scene;
        });
    }
    return _scene;
}

-(SCNView *)scnView {
    if (!_scnView) {
        _scnView = ({
            SCNView *view = [SCNView new];
            view.scene = self.scene;
            view.allowsCameraControl = NO;
            view.autoenablesDefaultLighting = NO;
            [self.view addSubview:view];
            view.translatesAutoresizingMaskIntoConstraints = NO;
            [self.view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-0-[view]-0-|" options:0 metrics:nil views:NSDictionaryOfVariableBindings(view)]];
            [self.view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-0-[view]-0-|" options:0 metrics:nil views:NSDictionaryOfVariableBindings(view)]];
            UILongPressGestureRecognizer *longPressGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(accumulateStrength:)];
            longPressGesture.minimumPressDuration = 0;
            longPressGesture.delegate = self;
            UIPanGestureRecognizer * pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
            pan.delegate = self;
//            view.gestureRecognizers = @[longPressGesture];
            view.gestureRecognizers = @[pan];
            view;
        });
    }
    return _scnView;
}

/**
 创建地板
 
 @discussion 用于光影效果，与落地判断
 */
-(SCNNode *)floor {
    if (!_floor) {
        _floor = ({
            SCNNode *node = [SCNNode node];
            node.geometry = ({
                SCNFloor *floor = [SCNFloor floor];
                //floor.firstMaterial.diffuse.contents = UIColor.clearColor;
                floor;
            });
            node.physicsBody = ({
                SCNPhysicsBody *body = [SCNPhysicsBody staticBody];
                body.restitution = 0;
                body.friction = 1;
                body.damping = 0.3;
                body.categoryBitMask = CollisionDetectionMaskFloor;
                body.collisionBitMask = CollisionDetectionMaskJumper|CollisionDetectionMaskPlatform|CollisionDetectionMaskOldPlatform;
                body.contactTestBitMask = CollisionDetectionMaskJumper;
                body;
            });
            [self.scene.rootNode addChildNode:node];
            node;
        });
    }
    return _floor;
}

/**
 初始化小人
 
 @discussion 小人是动态物体，自由落体到第一个台子中心，会受重力影响，会与台子和地板碰撞
 */
-(SCNNode *)jumper {
    if (!_jumper) {
        _jumper = ({
            SCNNode *node = [SCNNode node];
            node.geometry = ({
                SCNBox *box = [SCNBox boxWithWidth:1 height:1 length:1 chamferRadius:0];
                box.firstMaterial.diffuse.contents = UIColor.whiteColor;
                box;
            });
            node.physicsBody = ({
                SCNPhysicsBody *body = [SCNPhysicsBody dynamicBody];
                body.restitution = 0;
                body.friction = 1;
                body.rollingFriction = 1;
                body.damping = 0.3;
                body.allowsResting = YES;
                body.categoryBitMask = CollisionDetectionMaskJumper;
                body.collisionBitMask = CollisionDetectionMaskPlatform|CollisionDetectionMaskFloor|CollisionDetectionMaskOldPlatform;
                body;
            });
            //高度必须大于等于2
            node.position = SCNVector3Make(0, 1.9, 0);
            [self.scene.rootNode addChildNode:node];
            node;
        });
    }
    return _jumper;
}

/**
 初始化相机
 
 @discussion 光源随相机移动，所以将光源设置成相机的子节点
 */
-(SCNNode *)camera {
    if (!_camera) {
        _camera = ({
            SCNNode *node = [SCNNode node];
            node.camera = [SCNCamera camera];
            node.camera.zFar = 200.f;
            node.camera.zNear = .1f;
            [self.scene.rootNode addChildNode:node];
            //node.eulerAngles = SCNVector3Make(-M_PI * 0.25, M_PI * 0.25, 0);
            //node.eulerAngles = SCNVector3Make(-M_PI * 0.25, M_PI * 0.25, 0);
            node.eulerAngles = SCNVector3Make(-M_PI * 0.25, M_PI * 0.25, 0);
            node;
        });
        [_camera addChildNode:self.light];
    }
    return _camera;
}

-(SCNNode *)light {
    if (!_light) {
        _light = ({
            SCNNode *node = [SCNNode node];
            node.light = ({
                SCNLight *light = [SCNLight light];
                light.color = UIColor.whiteColor;
                light.type = SCNLightTypeOmni;
                light;
            });
            node;
        });
    }
    return _light;
}

#pragma mark UI事件
- (IBAction)restart {
    [self.view sendSubviewToBack:self.infoView];
    self.score = 0;
    [self.scnView removeFromSuperview];
    self.scnView = nil;
    self.scene = nil;
    self.floor = nil;
    self.lastPlatform = nil;
    self.platform = nil;
    self.nextPlatform = nil;
    self.jumper = nil;
    self.camera = nil;
    self.light = nil;
    if(self.scnView && self.floor && self.jumper) {
        [self createFirstPlatform];
    }
}

#pragma mark 隐藏状态栏
-(BOOL)prefersStatusBarHidden {
    return YES;
}

static double beginValue = 0.0;
static CGPoint originPoint;

- (void)onPan:(UIPanGestureRecognizer *)ges{
    switch (ges.state) {
        case UIGestureRecognizerStateBegan:{
            originPoint = [ges locationInView:ges.view];
        }
            break;
        case UIGestureRecognizerStateChanged:
        {
            CGPoint mpoint = [ges locationInView:ges.view];
            CGFloat xdis = mpoint.x - originPoint.x;
            CGFloat ydis = mpoint.y - originPoint.y;
            CGFloat factor = 1e-3;
            xdis = xdis * factor;
            ydis = ydis * factor;
            NSLog(@"xdis:%.3f", xdis);
            
            CGFloat pinch = ydis * 1e-1;
            SCNNode * camNode = self.camera;
            SCNVector3 euler = camNode.eulerAngles;
            
            //self.camera.eulerAngles = SCNVector3Make(euler.x + pinch, euler.y, euler.z);
            
            SCNVector3 rawPos = camNode.position;
            
            //int effect = 0;
            switch (2) {
                case 0:{
                    //x轴平移效果
                    camNode.position = SCNVector3Make(rawPos.x + xdis, rawPos.y, rawPos.z - xdis);
                }
                    break;
                case 1:{
                    //z轴平移效果
                    camNode.position = SCNVector3Make(rawPos.x - xdis , rawPos.y, rawPos.z - xdis);
                }
                    break;
                case 2:{
                    //叠加效果 x轴平移效果 + y轴平移
                    camNode.position = SCNVector3Make(rawPos.x + xdis, rawPos.y + ydis, rawPos.z - xdis);
                }
                    break;
                case 3:{
                    //叠加效果 z轴平移效果 + y轴平移
                    camNode.position = SCNVector3Make(rawPos.x - xdis , rawPos.y + ydis, rawPos.z - xdis);
                }
                    break;
                default:
                    break;
            }
            NSLog(@"x:%.2f y:%.2f z:%.2f",
                  camNode.position.x,
                  camNode.position.y,
                  camNode.position.z);
        }
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            break;
        default:
            break;
    }
    
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer{
    if ([gestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]]) {
        return NO;
    }
    return YES;
}

#define UsingMetal (0)

- (void)renderer:(id <SCNSceneRenderer>)renderer willRenderScene:(SCNScene *)scene atTime:(NSTimeInterval)time{
    
    if (UsingMetal) {
        [self dorenderWithMetal:renderer scene:scene atTime:time];
    }else{
        
    }

}

- (void)renderer:(id<SCNSceneRenderer>)renderer didRenderScene:(SCNScene *)scene atTime:(NSTimeInterval)time{
    if (UsingMetal) {
        [self dorenderWithMetal:renderer scene:scene atTime:time];
    }else{
        static int i = 0;
        int idx = i % 60;
        UIImage * image = [UIImage imageNamed:[NSString stringWithFormat:@"%d", idx]];
        i++;
        self.floor.geometry.firstMaterial.diffuse.contents = image;
        self.floor.geometry.firstMaterial.diffuse.contentsTransform = SCNMatrix4Rotate(SCNMatrix4Identity, 0, 45, 0, 0);
//        self.floor.geometry.firstMaterial.diffuse.contents = self.textureY;
        
    }
    
}

- (void)dorenderWithMetal:(id<SCNSceneRenderer>)renderer scene:(SCNScene *)scene atTime:(NSTimeInterval)time{
    
    NSUInteger w = self.computePipielineSate.threadExecutionWidth;
    NSUInteger h = self.computePipielineSate.maxTotalThreadsPerThreadgroup / w;
    NSLog(@"threadGroupSize😄:%d %d %d", w, h, self.computePipielineSate.maxTotalThreadsPerThreadgroup);
    
    id <MTLDevice> device = renderer.device;
    MTLRenderPassDescriptor * renderPassDescriptor = self.scnView.currentRenderPassDescriptor;
    if (!renderPassDescriptor) {
        return;
    }
    
    id <MTLCommandBuffer> commandBuffer = [renderer.commandQueue commandBuffer];
//    id <MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer]; //
    
    id <MTLRenderCommandEncoder> renderCommandEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
    
    //id <MTLRenderCommandEncoder> renderCommandEncoder = renderer.currentRenderCommandEncoder; //不应该使用当前的commander encoder
    renderCommandEncoder.label = [NSString stringWithFormat:@"%f", time];
    if (!renderCommandEncoder) {
        return;
    }
    renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0f);
    
    if (!self.renderPipelineState) {
        return;
    }
    
    [renderCommandEncoder setRenderPipelineState:self.renderPipelineState];
    
    [renderCommandEncoder setViewport:(MTLViewport){0, 0, self.scnViewSize.width, self.scnViewSize.height, -1.0, 1.0}];
    [renderCommandEncoder setRenderPipelineState:self.renderPipelineState];
    [renderCommandEncoder setVertexBuffer:self.vertexBuffer offset:0 atIndex:YYVideoVertexInputIndexVertexs];
    [renderCommandEncoder setFragmentBuffer:self.convertMatrix offset:0 atIndex:YYVideoConvertMatrixIndexYUVToRGB];
    // 设置Y UV纹理
    if (self.textureY) {
        [renderCommandEncoder setFragmentTexture:self.textureY atIndex:YYVidoTextureIndexYTexture];
//        self.textureY = nil;
    }
    
    if (self.textureUV) {
        [renderCommandEncoder setFragmentTexture:self.textureUV atIndex:YYVidoTextureIndexUVTexture];
//        self.textureUV = nil;
    }
    [renderCommandEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:self.vertexCount];
    
    [renderCommandEncoder endEncoding];
    

    
    
    [commandBuffer commit];
    
    NSLog(@"willRenderScene");
}

@end






