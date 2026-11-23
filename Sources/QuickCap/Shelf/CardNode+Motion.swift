import CoreGraphics

extension CardNode {
    // MARK: 飞入

    /// distance 是落到绳子上的位置（离屏幕边缘的距离）
    /// startOpacity 1：从截图界面那张飞出来的图接手，一开始就完全显示（不淡入），挂绳在路上才出现
    func beginFlight(from start: CGPoint, startScale: CGFloat, targetX distance: CGFloat, delay: CGFloat = 0, startOpacity: Float = 0) {
        phase = .flying
        flightFrom = start
        flightScale = startScale
        flightT = 0
        flightDelay = delay
        slide = Spring(distance)
        position = start
        scale = startScale
        opacity = startOpacity
        clipOpacity = startOpacity >= 1 ? 0 : 1
        container.zPosition = 10
    }

    /// 返回 true 表示刚刚落到绳子上。
    ///
    /// 路线是一条二次曲线，控制点在挂点正上方一点：先朝挂点斜着飞过去，最后几帧从上往下落到绳上，
    /// 像把照片挂到晾衣绳上。之前控制点在起点和挂点中间再往上 120pt，
    /// 卡片会先冲出屏幕顶边（被菜单栏挡住），再从屏幕外面掉回来。
    func stepFlight(dt: CGFloat, hangPoint: CGPoint) -> Bool {
        if flightDelay > 0 {
            // 等待时停在起点淡入
            flightDelay -= dt
            opacity = min(opacity + Float(dt / 0.06), 1)
            return false
        }
        flightT = min(flightT + dt / flightDuration, 1)
        let t = flightT
        // 起步快、末端减速，但留一点速度（线性那部分），落到绳上有一下"挂上去"的感觉
        let k: CGFloat = 0.12
        let e = (1 - k) * (1 - (1 - t) * (1 - t)) + k * t
        let control = CGPoint(x: hangPoint.x, y: min(flightFrom.y, hangPoint.y) - Metrics.flightLift)
        let u = 1 - e
        position = CGPoint(x: u * u * flightFrom.x + 2 * u * e * control.x + e * e * hangPoint.x,
                           y: u * u * flightFrom.y + 2 * u * e * control.y + e * e * hangPoint.y)
        // 缩小比位移早一点完成，落到绳上之前已经是卡片大小
        let se = 1 - pow(1 - t, 3)
        scale = flightScale + (1 - flightScale) * se
        opacity = max(opacity, Float(min(t / 0.1, 1)))
        // 挂绳在后半程出现，挂上去时已经在了
        if clipOpacity < 1 { clipOpacity = max(clipOpacity, Float(min(max((t - 0.35) / 0.4, 0), 1))) }
        // 飞行中朝前进方向略微倾斜，越接近终点越正
        let dir: CGFloat = hangPoint.x >= flightFrom.x ? 1 : -1
        angle = ReduceMotion.isOn ? 0 : dir * 0.08 * sin(.pi * t)

        guard t >= 1 else { return false }
        land(at: hangPoint, direction: dir)
        clipOpacity = 1
        onLanded?()
        onLanded = nil
        return true
    }

    /// 落到绳子上。飞行结束时角度已经回正，这里从正下方开始，
    /// 顺着飞来的方向给一个速度，让卡片自己荡出去，不会突然跳到某个角度。
    private func land(at point: CGPoint, direction: CGFloat) {
        phase = .hanging
        hang = point
        scale = 1
        opacity = 1
        container.zPosition = 0
        angle = 0
        bob = CGPoint(x: point.x, y: point.y + length)
        bobPrev = bob
        lastSwingStep = 1.0 / 240
        lastHangDelta = 0
        push(angle: direction * Metrics.landingSwing)
    }

    // MARK: 摆动

    /// 摆动的角频率。按固定频率反推重力，大卡片和小卡片摆得一样快。
    var swingOmega: CGFloat { 2 * .pi * Metrics.swingFrequency }

    /// 挂点跟着绳子动，卡片重心跟着挂点摆。
    /// scrollDelta、revealDelta 是这一步整排滚动、展开收起带来的横向位移（屏幕坐标），
    /// 分别按 scrollSwingInertia、revealSwingInertia 算惯性。
    func stepSwing(dt: CGFloat, hangPoint: CGPoint, scrollDelta: CGFloat = 0, revealDelta: CGFloat = 0) {
        stepPendingSway(dt)
        // 挂点移动（换位置、绳子回弹、展开收起）时，大部分位移直接带着卡片走，
        // 只留 swingInertia 这一份让卡片"跟不上"而摆起来，否则滑动一段距离就会被甩到很大的角度。
        // 在挂点坐标系里积分：rel 是重心相对挂点的位置，relPrev 是上一步的。
        // 挂点加速时，卡片在挂点坐标系里受到反向的惯性力。用两步位移之差（加速度 × dt²）算，
        // 匀速滑动不会越摆越大。只算横向：展开收起时竖直加速度很大，算进去会把"重力"抵消掉。
        let hd = CGPoint(x: hangPoint.x - hang.x, y: hangPoint.y - hang.y)
        var rel = CGPoint(x: bob.x - hang.x, y: bob.y - hang.y)
        var relPrev = CGPoint(x: bobPrev.x - hang.x, y: bobPrev.y - hang.y)
        // 把滚动那部分位移换算成按 swingInertia 计的等效位移，两种来源的惯性分开调
        let k = Metrics.swingInertia
        let effective = hd.x + scrollDelta * (Metrics.scrollSwingInertia / k - 1)
            + revealDelta * (Metrics.revealSwingInertia / k - 1)
        // 减少动态效果：挂点怎么动都不甩，卡片一直竖直挂着
        rel.x -= (effective - lastHangDelta) * (ReduceMotion.isOn ? 0 : Metrics.swingInertia)
        lastHangDelta = effective
        hang = hangPoint
        lastSwingStep = dt

        let w = swingOmega
        let gravity = w * w * length
        // 阻尼比 ζ 对应速度每秒衰减 exp(-2ζω)
        let keep = exp(-2 * Metrics.swingDampingRatio * w * dt)
        let maxStep = maxSwingSpeed * dt
        let vx = max(min((rel.x - relPrev.x) * keep, maxStep), -maxStep)
        let vy = (rel.y - relPrev.y) * keep
        relPrev = rel
        rel.x += vx
        rel.y += vy + gravity * dt * dt

        let d = max(sqrt(rel.x * rel.x + rel.y * rel.y), 0.001)
        rel = CGPoint(x: rel.x / d * length, y: rel.y / d * length)
        bob = CGPoint(x: hang.x + rel.x, y: hang.y + rel.y)
        bobPrev = CGPoint(x: hang.x + relPrev.x, y: hang.y + relPrev.y)
        // 重心在挂点正下方时角度为 0；重心偏左（rel.x<0）时卡片顺时针转
        angle = atan2(-rel.x, rel.y)

        // 兜底：摆角超过硬上限就停在上限，并吃掉一半速度
        let hard = Metrics.swingHardLimit
        if abs(angle) > hard {
            let a = angle > 0 ? hard : -hard
            let v = CGPoint(x: bob.x - bobPrev.x, y: bob.y - bobPrev.y)
            bob = CGPoint(x: hang.x - sin(a) * length, y: hang.y + cos(a) * length)
            bobPrev = CGPoint(x: bob.x - v.x * 0.5, y: bob.y - v.y * 0.5)
            angle = a
        }
    }

    /// 从正下方出发、能摆到 swingMaxAngle 的速度（pt/秒）。
    private var maxSwingSpeed: CGFloat { Metrics.swingMaxAngle * swingOmega * length }

    /// 给摆动一个横向推力（pt/秒，正数向右）。多次推力会累加，但推出来的摆角不超过 maxAngle。
    /// 如果卡片已经摆得比上限大（比如刚落下），这次推力不会再加大它，也不会把它硬拉小。
    func nudge(_ speed: CGFloat, maxAngle: CGFloat = Metrics.swingMaxAngle) {
        guard phase == .hanging, !ReduceMotion.isOn else { return }
        let h = max(lastSwingStep, 1.0 / 480)
        let current = (bob.x - bobPrev.x) / h
        let limit = max(maxAngle * swingOmega * length, abs(current))
        let next = max(min(current + speed, limit), -limit)
        bobPrev.x = bob.x - next * h
    }

    /// 推一下，让卡片从当前位置大约摆到 angle 这么大（弧度，正数向右推）。
    func push(angle amplitude: CGFloat) {
        nudge(amplitude * swingOmega * length)
    }

    private func stepPendingSway(_ dt: CGFloat) {
        guard let sway = pendingSway else { return }
        let left = sway.delay - dt
        if left > 0 {
            pendingSway = (left, sway.angle)
        } else {
            pendingSway = nil
            push(angle: sway.angle)
        }
    }

    /// 不经过飞入，直接挂在 point 上（启动时恢复用）
    func hangImmediately(at point: CGPoint) {
        phase = .hanging
        hang = point
        scale = 1
        opacity = 1
        container.zPosition = 0
        angle = 0
        bob = CGPoint(x: point.x, y: point.y + length)
        bobPrev = bob
        lastHangDelta = 0
    }

    func setPinned(_ pinned: Bool, animated: Bool) {
        isPinned = pinned
        if !animated { snapPinnedLevel() }
        if animated { push(angle: 0.05) }
    }

    func resetSwing() {
        guard phase == .hanging else { return }
        bob = CGPoint(x: hang.x, y: hang.y + length)
        bobPrev = bob
        angle = 0
        lastHangDelta = 0
        pendingSway = nil
    }

    // MARK: 掉落

    func beginFall() {
        let wasHanging = phase == .hanging
        phase = .falling
        if wasHanging { position = hang }
        let swingV = (bob.x - bobPrev.x) / max(lastSwingStep, 1.0 / 480)
        velocity = CGPoint(x: swingV * 0.4 + CGFloat.random(in: -60...60), y: -CGFloat.random(in: 120...200))
        spin = ReduceMotion.isOn ? 0 : CGFloat.random(in: 1.2...2.4) * (Bool.random() ? 1 : -1)
        fallAge = 0
        container.zPosition = 20
    }

    /// 返回 true 表示已经完全消失，可以移除。
    func stepFall(dt: CGFloat, floor: CGFloat) -> Bool {
        fallAge += dt
        velocity.y += 2600 * dt
        position.x += velocity.x * dt
        position.y += velocity.y * dt
        angle += spin * dt
        if fallAge > 0.35 { opacity = max(opacity - Float(dt * 2.6), 0) }
        return opacity <= 0 || position.y > floor
    }

    // MARK: 悬停

    func stepHover(_ dt: CGFloat) {
        let rate = hoverTarget > hover ? Metrics.hoverRiseRate : Metrics.hoverFallRate
        let k = 1 - exp(-rate * dt)
        hover += (hoverTarget - hover) * k
        if abs(hoverTarget - hover) < 0.002 { hover = hoverTarget }
    }

    var isSettled: Bool {
        switch phase {
        case .flying, .falling: return false
        case .hanging:
            let motion = abs(bob.x - bobPrev.x) + abs(bob.y - bobPrev.y)
            // 摆到最高点时速度也接近 0，还要看角度，否则会停在歪着的位置
            return slide.isSettled && motion < 0.004 && abs(angle) < 0.003 && hover == hoverTarget && pendingSway == nil
        }
    }
}
