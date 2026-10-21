# GOHAN: Tự động đổi tên file .3105 trong IPA trên GitHub Actions

## Kết quả
Đổi duy nhất các đường dẫn `Payload/OGIOS.app/OGIOS File (1).3105` ... `(14).3105` thành `Payload/OGIOS.app/GOHAN File (1).3105` ... `(14).3105`.
Không xóa dữ liệu, không sửa từng byte bên trong file, không đụng tệp thực thi Mach-O `OGIOS`, `.app`, `Info.plist`, cấu hình License, hoặc thuật toán Patch/Un-Patch.

**Lưu ý:** Việc thay tên file tài nguyên có thể ảnh hưởng nếu mã ứng dụng tham chiếu trực tiếp tên cũ. Trong IPA đầu vào không tìm thấy chuỗi `OGIOS File` ở dạng ASCII nguyên văn trong binary, tuy nhiên điều này không chứng minh 100% an toàn trên iPhone. Kiểm thử sau build là bắt buộc.

## Bước 1: Thêm file vào GitHub
Tại repository đang dùng để build IPA, tạo `scripts/rebrand_ipa.py` bằng cách upload file cùng tên trong thư mục scripts của gói này. **Không tải ZIP này lên dưới dạng một file duy nhất**.

## Bước 2: Thêm vào workflow build iOS
Vào `.github/workflows/<workflow-đang-build-IPA>.yml`, tìm bước Xcode build/export tạo IPA. Sau khi có IPA và **trước** bước `actions/upload-artifact` (hoặc publish Release), thêm bước:

```yaml
      - name: GOHAN - Rename 14 sample patches before IPA upload
        shell: bash
        run: |
          set -euo pipefail
          found=0
          while IFS= read -r -d '' ipa; do
            found=$((found + 1))
            echo "Checking $ipa"
            python3 scripts/rebrand_ipa.py "$ipa" --in-place
            python3 scripts/rebrand_ipa.py "$ipa" --check
          done < <(find . -type f -name '*unsigned*.ipa' -print0)
          if [ "$found" -eq 0 ]; then
            echo "ERROR: Khong tim thay IPA unsigned. Kiem tra duong dan build." >&2
            exit 1
          fi
```

**Cần chỉnh mẫu `find` đúng thư mục/tên IPA được upload từ workflow của bạn**. Nếu nó không khớp với IPA thật, bước trên không chạy trên file nào. Ví dụ nếu workflow tạo `build/GooHanPatch.ipa`, dùng `python3 scripts/rebrand_ipa.py "build/GooHanPatch.ipa" --in-place` trực tiếp. Bạn có thể gửi YAML workflow để chỉnh chính xác.

Đây là bước POST-BUILD. Chạy trước khi ký mã (codesign); với IPA unsigned được cung cấp, phù hợp. Nếu Actions còn bước tạo IPA sau đoạn này, bạn đặt sai vị trí.

## Bước 3: Build lại và tải IPA từ GitHub
Commit script + workflow, vào GitHub Actions > Run workflow, tải artifact mới. Chạy:

```
python3 scripts/rebrand_ipa.py GooHanPatch-experimental-unsigned.ipa --check
```

Nếu thành công, hiển thị `PASS: all 14 .3105 files are named GOHAN`.

## Giới hạn quan trọng
- `Payload/OGIOS.app/` và executable `OGIOS` không đổi vì thuộc bộ binary/module Swift; thay tên không có source Xcode có thể làm ứng dụng hỏng.
- Nếu mục tiêu là loại bỏ hoàn toàn chuỗi OGIOS ở cả Swift binary + metadata, phải chỉnh Xcode project/source và build lại, không nên sửa thẳng hàng nghìn chuỗi OGIOS trong Mach-O.
- Chỉ kiểm tra tên và byte tài nguyên; chưa xác minh vận hành tính năng Patch/Un-Patch trên iPhone.
- Nếu nguồn dự án thực sự có các file `.3105`, có thể đổi trực tiếp trong source và sửa references trong Xcode để không cần post-build. Bộ này hữu ích khi bạn muốn mọi IPA *tải từ GitHub Actions* đều đã đổi tên.
