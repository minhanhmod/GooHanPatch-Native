# GooHan Patch — Bản hợp nhất engine 3106 (release candidate)

## Nhánh và phiên bản tham chiếu

- Nhánh phát triển mới: `gohan-official-3106`.
- Nhánh đã được người dùng xác nhận Apply/Restore thành công trên iOS 27: `gohan-hybrid-ios27-test` (**không sửa**).
- Nguồn engine đầy đủ: `QuinnTang74/3106`, commit `832bad906c06d92f55cabf799166f00d45d6a978`.
- Nhánh mới dùng engine 3106 (bao gồm kernel / bad_query / worse_query) với bản vá UI/License riêng của GooHan.

## Đã tích hợp

1. GooHan làm màn hình chính, không còn nút đóng lớp phủ để đi vào UI 3106 không kiểm License.
2. Giao diện hồng/đen nền lưới, icon GooHan, 24 màu, danh mục từ Admin.
3. Định dạng gói tự động: iOS 26.7+/27.x → 3106; phiên bản trước → 3105. Người dùng đổi thủ công trong Cài đặt.
4. Apply/Restore gọi đúng `DevicePatchService` của 3106, lưu biên nhận, không báo thành công chỉ dựa vào trạng thái công tắc.
5. Phục hồi cục bộ vẫn có thể dùng khi License hết hạn, đổi định dạng hoặc gói bị gỡ khỏi danh mục.
6. iOS 17/18 có nút **kích hoạt thủ công** cho kernel backend, tránh khởi chạy nguy hiểm khi mở ứng dụng.
7. API License/đồng bộ Admin ZCloudViet giữ nguyên từ bản đã hoạt động.
8. `worse_query.m`, `SandboxAccess.swift`, `KernelExploit.swift`, `DevicePatchService.swift` và `PatchTransaction.swift` upstream không bị sửa.

## Build

Vào GitHub Actions → `Build GooHan Patch - Official 3106 candidate` → tìm job `build-goohan-full-3106`.

Artifact: `GooHan-Patch-official-candidate-3106`, chứa IPA unsigned và mã nguồn GPL.

Bản này **chưa được xác nhận build xanh / thử nghiệm trên iOS cũ** tại thời điểm viết tài liệu. Không đổi tên thành bản phát hành ổn định chỉ vì code đã commit.

## Lưu ý cài đặt

- IPA chưa ký; ký với provisioning profile/App Groups phù hợp cho iOS 27.
- Bundle ID của mã nguồn tham chiếu là `com.qingtang.3106`, chỉ thay đổi display name và icon.
- Nếu thay Bundle ID hoặc nhóm ký, dữ liệu biên nhận trong container ứng dụng trước đó có thể không chuyển sang. Hãy **khôi phục mọi gói đang bật trong app hiện tại trước khi thay ứng dụng/ID**.
- Không xóa bản IPA GooHan iOS 27 đã hoạt động trước khi xác nhận khôi phục trên bản mới.
- Tôn trọng GPL-3.0 của mã nguồn gốc: giữ giấy phép, NOTICE và mã nguồn tương ứng.

## Còn cần xác nhận

- Kết quả biên dịch Swift/Xcode trong GitHub Actions trên nhánh mới.
- Apply và Restore cùng một gói trên iOS 27 với UI mới.
- Backend các phiên bản iOS 17/18/26 trên thiết bị thực.
- Kiểm tra trạng thái cũ còn hợp lệ sau cập nhật đè; không thay đổi Bundle ID khi đang có gói bật.
