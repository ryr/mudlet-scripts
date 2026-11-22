function createRotator(list)
    local total = #list
    local rotator = {
        index = 1
    }

    -- 1. Следующий элемент (строго по порядку списка)
    function rotator.next()
        if total == 0 then return nil end
        rotator.index = rotator.index % total + 1
        local item = list[rotator.index]
        return item.value
    end

    -- 2. Текущий элемент (или первый, если еще не шагали)
    function rotator.current()
        if total == 0 then return nil end
        local currentIndex = rotator.index == 0 and 1 or rotator.index
        local item = list[currentIndex]
        return item.value
    end

    -- 3. Сброс
    function rotator.reset()
        rotator.index = 1
    end

    -- Дополнительная функция: проверка, есть ли ключ в ротации
    function rotator.hasKey(searchKey)
        for i = 1, total do
            if list[i].key == searchKey then
                return true
            end
        end
        return false
    end

    return rotator
end
