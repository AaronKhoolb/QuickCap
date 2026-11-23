import AppKit

/// 卡片多到一排放不下时，用触控板左右滑或鼠标滚轮横向滚动整排卡片。
/// 卡片在绳子上滑动，挂点一动卡片就会轻轻摆，和换位置时一样。
extension ShelfView {
    /// 松手、新卡片加入时：软一点的弹簧滑过去，越界时弹回来
    private static let settleSpring = (stiffness: CGFloat(170), damping: CGFloat(25))
    /// 鼠标滚轮一格一格：快一点到位（临界阻尼，不回弹），不会觉得拖泥带水
    private static let wheelSpring = (stiffness: CGFloat(520), damping: CGFloat(45.6))
    /// 手指在触控板上、惯性滑动时怎么跟（alpha-beta 跟踪，和系统、游戏里跟手的做法一样）：
    /// 触控板的事件和屏幕刷新不同步，事件的间隔也不匀（有时两帧之间没来、下一帧来两个；同样的手速，这一下 25pt 下一下 49pt）。
    /// 每来一个事件，按它自己的时间戳更新"手指在哪、多快"：位置往这个事件靠 followAlpha，速度往它算出的速度靠 followBeta；
    /// 每一帧画的是"手指在这一帧显示出来那一刻应该在哪"（按速度从最后一个事件往前推，最多推 followAhead）。
    /// 所以每帧挪的距离是匀的，又不落后手指。拿用户三次真实的触控板记录回放，最不匀的那些帧比上一版好一半，落后一样（约一帧）
    static let followAlpha: CGFloat = 0.3
    static let followBeta: CGFloat = 0.05
    static let followAhead: CFTimeInterval = 0.017
    /// 松手后的惯性：不跟着系统一个个的惯性事件走（它们到得不匀：53、53、52、50、没有、98、46……，跟着走快速滑时就一顿一冲），
    /// 自己按同一条减速曲线滑：每毫秒速度剩 coastDecay（从用户真实的触控板记录里量的，系统的惯性也是这样减速）。
    /// 起始速度用系统给的第一下惯性。回放用户三次记录：快速滑时最不匀的那 10% 的帧从 13–17% 降到约 1%，滑的总距离和系统差 5–10%
    static let coastDecay: CGFloat = 0.997
    /// 松手：不等系统的惯性事件（它要隔一会儿才来，这段时间以前卡片先停下、再一下冲出去），马上按屏幕上现在的速度自己滑；
    /// 系统的惯性来了，速度在这么多秒左右顺过去。拿用户真实记录回放：松手那一下前后两帧的速度差从 50–70% 降到 5% 以内
    static let coastBlend: CGFloat = 0.05
    /// 惯性滑到头越过去的那一截：弹簧（比回位的硬一点，不拖）和屏幕上最多显示多远
    static let edgeSpring = (stiffness: CGFloat(300), damping: CGFloat(35))
    static let edgeLimit: CGFloat = 90
    /// 越界拉扯的最大距离（pt）
    private static let rubberBandLimit: CGFloat = 90

    /// 把滚动事件的位移换算成滚动量的变化。
    /// scrollingDeltaX 是内容应该跟着移动的横向距离（向右为正），系统已经按"自然滚动"的设置换算好，
    /// 和普通滚动视图一样：开着自然滚动时就是手指移动的方向。卡片要跟着内容走：
    /// 滚动量变大时整排往左移，所以滚动量的变化是 -dx。
    /// 竖着滑（包括普通鼠标滚轮）：往下滚看更旧的卡片（更右边的）。左右两边出来都一样。
    func scrollDelta(dx: CGFloat, dy: CGFloat) -> CGFloat {
        abs(dx) >= abs(dy) ? -dx : -dy
    }

    /// 滑到指定位置（会被限制在可滚动范围里）
    func settleScroll(to target: CGFloat) {
        scrollFollow = false
        coast = nil
        edgeBounce = nil
        scroll.stiffness = Self.settleSpring.stiffness
        scroll.damping = Self.settleSpring.damping
        scroll.target = clampScroll(target)
        wake()
    }

    /// 跟手滚动 delta（pt，正数表示内容往左走、看右边的卡片）。越界时阻力越来越大。
    func trackScroll(by delta: CGFloat, at time: TimeInterval? = nil) {
        if !scrollFollow { followPos = scroll.value; followVelocity = 0; lastFollowEvent = nil }
        scrollFollow = true
        let t = scroll.target
        let over = t < minScroll ? minScroll - t : max(t - maxScroll, 0)
        let pushingOut = (t < minScroll && delta < 0) || (t > maxScroll && delta > 0)
        let k = pushingOut ? pow(max(1 - over / Self.rubberBandLimit, 0), 2) * 0.55 : 1
        scroll.target = t + delta * k
        // 跟踪手指：scroll.target 是手指现在真正在的地方（越界时已经加了阻力）
        let now = time ?? CACurrentMediaTime()
        if let last = lastFollowEvent {
            let dt = CGFloat(max(now - last, 0.002))
            let predicted = followPos + followVelocity * dt
            let miss = scroll.target - predicted
            followPos = predicted + Self.followAlpha * miss
            followVelocity += Self.followBeta * miss / dt
        } else {
            // 第一个事件：位置直接到手指那里，速度按一帧的一半起步（按一整帧算会往前推过头一点，开头那一下冲一冲）
            followPos = scroll.target
            followVelocity = (scroll.target - t) * 60
        }
        lastFollowEvent = now
        lastFollowEventMedia = CACurrentMediaTime()
        wake()
    }

    override func scrollWheel(with event: NSEvent) {
        lastScrollEventAt = CACurrentMediaTime()
        guard isShown, canScroll else {
            // 不处理滚动了，但手势结束要记下来（不然"正在滑"的标记一直挂着，悬停、点击都失灵）
            if event.phase.contains(.ended) || event.phase.contains(.cancelled)
                || event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                isScrollGestureActive = false
                wake()
            }
            super.scrollWheel(with: event)
            return
        }
        let precise = event.hasPreciseScrollingDeltas
        let dx = event.scrollingDeltaX * (precise ? 1 : 12)
        let dy = event.scrollingDeltaY * (precise ? 1 : 12)
        let phase = event.phase, momentum = event.momentumPhase
        // 一次手势只认一个方向：手指一按下先看头几下往哪边多，之后（包括松手后的惯性）都只用那个方向。
        // 以前每个事件各自挑横的还是竖的：斜着一点滑时两个方向差不多大，一下用横的一下用竖的（正负还可能相反），
        // 整排就一前一后地抖，看起来一卡一跳
        if phase.contains(.began) || phase.contains(.mayBegin) {
            gestureAxis = nil; gestureAccum = .zero
            // 手指一放上去：正在滑的（惯性、回弹）马上停在原地，和系统的滚动一样
            scroll.target = scroll.value
            scroll.velocity = 0
            scrollFollow = true
            coast = nil
            edgeBounce = nil
            followPos = scroll.value
            followVelocity = 0
            lastFollowEvent = nil
        }
        var delta: CGFloat
        if phase.isEmpty && momentum.isEmpty {
            delta = scrollDelta(dx: dx, dy: dy)
        } else {
            if gestureAxis == nil {
                gestureAccum.x += abs(dx); gestureAccum.y += abs(dy)
                if gestureAccum.x + gestureAccum.y >= 4 { gestureAxis = gestureAccum.x >= gestureAccum.y ? .horizontal : .vertical }
            }
            switch gestureAxis ?? (abs(dx) >= abs(dy) ? .horizontal : .vertical) {
            case .horizontal: delta = -dx
            case .vertical: delta = -dy
            }
        }
        // 滚动时卡片会从鼠标下面滑走，先收起悬停，停下后再按鼠标位置重新判断
        pendingHoverPoint = layerPoint(convert(event.locationInWindow, from: nil))
        if hovered != nil { clearHover() }

        userScrolling = true
        jumpLabelIndex = nil
        if phase.contains(.began) || phase.contains(.mayBegin) || momentum.contains(.began) {
            isScrollGestureActive = true
        }
        if phase.isEmpty && momentum.isEmpty {
            // 普通鼠标滚轮：一格一格地滑过去
            scrollFollow = false
            coast = nil
            edgeBounce = nil
            scroll.stiffness = Self.wheelSpring.stiffness
            scroll.damping = Self.wheelSpring.damping
            scroll.target = clampScroll(scroll.target + delta)
            wake()
        } else if phase.contains(.began) || phase.contains(.changed) {
            // 手指刚开始滑的那一下也带着位移（快速滑时能有 100–200pt），以前只认"进行中"的事件，这一截丢了：
            // 卡片要从后面追，第一下就像卡了一下
            trackScroll(by: delta, at: event.timestamp)
        } else if momentum.contains(.began) {
            // 惯性开始：自己滑（见 coastDecay）。已经拉过头了就直接弹回去
            if coast != nil {
                // 松手时已经自己在滑了：从屏幕上现在的速度顺到系统给的惯性速度
                coast = (start: nil, from: 0, v0: scroll.velocity, vs: delta * 120)
                wake()
            } else if edgeBounce != nil {
                // 已经滑到头在弹了，不管
            } else if scroll.target != clampScroll(scroll.target) {
                settleScroll(to: scroll.target)
            } else {
                coast = (start: nil, from: 0, v0: delta * 120, vs: delta * 120)
                scrollFollow = true
                wake()
            }
        } else if momentum.contains(.changed) {
            // 系统后面的惯性事件不用（自己在滑）
        }
        if phase.contains(.ended) || phase.contains(.cancelled)
            || momentum.contains(.ended) || momentum.contains(.cancelled) {
            // 松手：可能马上接着惯性滑动（momentum began 会重新标记）。
            // 在范围里：接着跟到手指停的地方就好（换成弹簧的话，手指的速度会让它冲过头再回来）；越界了才用弹簧弹回去
            isScrollGestureActive = false
            let fingerLift = phase.contains(.ended) || phase.contains(.cancelled)
            if fingerLift, coast == nil, scroll.target == clampScroll(scroll.target),
               let last = lastFollowEvent, event.timestamp - last < 0.03, scrollFollow, abs(scroll.velocity) >= 12 {
                // 手指还在动就松开：马上按屏幕上现在的速度滑（系统的惯性来了再顺过去，见 coastBlend）
                coast = (start: nil, from: 0, v0: scroll.velocity, vs: scroll.velocity)
                wake()
            } else if coast == nil, edgeBounce == nil {
                if scroll.target != clampScroll(scroll.target) { settleScroll(to: scroll.target) } else { wake() }
            }
        }
        delegate?.shelfViewDidInteract(self)
    }

    enum GestureAxis { case horizontal, vertical }

    /// 根图层坐标的点是否在整排卡片所在的横条里（能滚动时，卡片之间的空隙也接收滚动）
    func isInScrollBand(_ p: CGPoint) -> Bool {
        guard isShown, canScroll else { return false }
        let top = rope.leftAnchor.y - 4
        let bottom = rope.leftAnchor.y + 40 + Metrics.clipGripY + Metrics.cardMaxSize.height
        return p.y >= top && p.y <= bottom
    }
}
